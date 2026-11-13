import Cocoa
import Darwin
import Foundation
import SleepSkipCore
import SwiftUI

enum IPCNotifications {
    static let openPopover = Notification.Name("io.github.laiyongqiang.SleepSkip.OpenPopover")
    static let cliStarted = Notification.Name("io.github.laiyongqiang.SleepSkip.CLIStarted")
    static let cliStopped = Notification.Name("io.github.laiyongqiang.SleepSkip.CLIStopped")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var displayTimer: Timer?
    private var keyMonitor: Any?
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?
    private var cliProcessSource: DispatchSourceProcess?
    private var wakeObserver: NSObjectProtocol?
    private var agentMonitor: AgentActivityMonitor?

    private let store = PreferencesStore()
    let sessionManager: SessionManager

    override init() {
        self.sessionManager = SessionManager(
            store: store,
            caffeinateRunner: CaffeinateRunner(),
            backpackGuard: BackpackGuard(),
            powerMonitor: PowerMonitor(),
            screenLocker: ScreenLocker(),
            notifier: NativeNotifier(),
            loginItem: LoginItemManager()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        setupSignalHandlers()
        setupDistributedNotifications()
        setupWorkspaceNotifications()
        setupStatusItem()
        setupPopover()
        setupKeyboardShortcuts()

        sessionManager.onStateChange = { [weak self] active, closedLid in
            self?.updateStatusItemAppearance(active: active, closedLid: closedLid)
        }
        sessionManager.onRequestClosePopover = { [weak self] in
            self?.closePopover()
        }
        sessionManager.onAutoFollowToggled = { [weak self] enabled in
            self?.applyAutoFollow(enabled)
        }
        if sessionManager.isAutoFollowEnabled {
            applyAutoFollow(true)
        }

        updateStatusItemAppearance(
            active: sessionManager.isEffectivelyActive,
            closedLid: sessionManager.activeClosedLid
        )

        let shouldOpen = CommandLine.arguments.contains("--open") || !store.hasShownOnboarding
        store.hasShownOnboarding = true
        if shouldOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.showPopover()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = URLCommandParser.parse(url) else { continue }
            sessionManager.applyURLCommand(command)
            if case .open = command {
                showPopover()
            }
        }
    }

    private func terminateIfDuplicateInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    IPCNotifications.openPopover,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                return true
            }
        }
        return false
    }

    private func setupDistributedNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleExternalOpenRequest),
            name: IPCNotifications.openPopover,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleCLIStarted(_:)),
            name: IPCNotifications.cliStarted,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleCLIStopped(_:)),
            name: IPCNotifications.cliStopped,
            object: nil
        )
    }

    private func applyAutoFollow(_ enabled: Bool) {
        agentMonitor?.stop()
        agentMonitor = nil
        guard enabled else { return }

        let monitor = AgentActivityMonitor(
            tracker: sessionManager.agentTracker,
            onStateChange: { [weak self] state in
                DispatchQueue.main.async {
                    self?.sessionManager.handleAgentActivity(state)
                }
            },
            onSessionLimitReached: { [weak self] in
                DispatchQueue.main.async {
                    self?.sessionManager.handleAutoFollowLimitReached()
                }
            }
        )
        monitor.start()
        agentMonitor = monitor
    }

    /// Sources whose directories exist, for display in preferences.
    private var availableAgentSources: [AgentSource] {
        AgentSource.defaults().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func setupWorkspaceNotifications() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sessionManager.reconcileOnWakeOrShow()
        }
    }

    @objc private func handleExternalOpenRequest() {
        DispatchQueue.main.async {
            self.showPopover()
        }
    }

    @objc private func handleCLIStarted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let pidNum = info["pid"] as? NSNumber else { return }
        let pid = pidNum.int32Value
        let name = (info["cmd"] as? String) ?? "cli"
        let modeRaw = (info["mode"] as? String) ?? GuardMode.background.rawValue
        let mode = GuardMode(rawValue: modeRaw) ?? .background

        DispatchQueue.main.async {
            self.watchExternalCLIPID(pid)
            self.sessionManager.setExternalCLISession(
                ExternalCLISession(pid: pid, commandName: name, mode: mode)
            )
        }
    }

    @objc private func handleCLIStopped(_ notification: Notification) {
        DispatchQueue.main.async {
            self.stopWatchingExternalCLI()
            self.sessionManager.setExternalCLISession(nil)
        }
    }

    /// Pure kernel kqueue monitor (zero polling / 0% CPU) that cleans up CLI badge if CLI terminates abnormally.
    private func watchExternalCLIPID(_ pid: Int32) {
        stopWatchingExternalCLI()
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.stopWatchingExternalCLI()
            self?.sessionManager.setExternalCLISession(nil)
        }
        source.resume()
        cliProcessSource = source
    }

    private func stopWatchingExternalCLI() {
        cliProcessSource?.cancel()
        cliProcessSource = nil
    }

    private func setupSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            NSApp.terminate(nil)
        }
        term.resume()
        sigTermSource = term

        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intr.setEventHandler {
            NSApp.terminate(nil)
        }
        intr.resume()
        sigIntSource = intr
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let rootView = SleepSkipPopoverView(manager: sessionManager)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    private func setupKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }

            // Cmd + , -> toggle settings
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.sessionManager.showSettings.toggle()
                return nil
            }

            // Cmd + Q -> clean quit
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
                self.sessionManager.stopSession(reason: .silent)
                NSApp.terminate(nil)
                return nil
            }

            // Esc -> back or close popover
            if event.keyCode == 53 {
                if self.sessionManager.showSettings {
                    self.sessionManager.showSettings = false
                } else if self.sessionManager.showCustomInput {
                    self.sessionManager.showCustomInput = false
                } else {
                    self.closePopover()
                }
                return nil
            }

            // Return / NumPad Enter
            if event.keyCode == 36 || event.keyCode == 76 {
                if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                    return event
                }
                if self.sessionManager.showSettings {
                    return event
                }
                if self.sessionManager.isRunning {
                    self.closePopover()
                } else {
                    self.sessionManager.startConfiguredSession()
                }
                return nil
            }

            return event
        }
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }
        togglePopover()
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        sessionManager.reconcileOnWakeOrShow()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startDisplayTimer()
    }

    func closePopover() {
        popover.performClose(nil)
        stopDisplayTimer()
    }

    private func showContextMenu() {
        let t = sessionManager.l10n
        let menu = NSMenu()

        let openItem = NSMenuItem(title: t.menuOpenPanel, action: #selector(menuOpenPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        if sessionManager.isRunning {
            let stopItem = NSMenuItem(title: t.menuStop, action: #selector(menuStop), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: t.menuQuickStart, action: #selector(menuQuickStart), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        let lockItem = NSMenuItem(title: t.lockScreenButton, action: #selector(menuLockScreen), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: t.launchAtLoginLabel, action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = sessionManager.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        let settingsItem = NSMenuItem(title: t.settingsTitle, action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: t.quitButton, action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        sessionManager.showSettings = false
        showPopover()
    }

    @objc private func menuQuickStart() {
        sessionManager.startConfiguredSession()
    }

    @objc private func menuStop() {
        sessionManager.stopSession(reason: .manual)
    }

    @objc private func menuLockScreen() {
        ScreenLocker.lockScreenImmediate()
    }

    @objc private func menuToggleLaunchAtLogin() {
        sessionManager.toggleLaunchAtLogin(!sessionManager.launchAtLogin)
    }

    @objc private func menuOpenSettings() {
        sessionManager.showSettings = true
        showPopover()
    }

    @objc private func menuQuit() {
        sessionManager.stopSession(reason: .silent)
        NSApp.terminate(nil)
    }

    // MARK: - NSPopoverDelegate (Event-driven display timer)

    func popoverWillShow(_ notification: Notification) {
        sessionManager.reconcileOnWakeOrShow()
        startDisplayTimer()
    }

    func popoverDidClose(_ notification: Notification) {
        stopDisplayTimer()
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.sessionManager.refreshDisplayTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateStatusItemAppearance(active: Bool, closedLid: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        if active {
            symbolName = closedLid ? "lock.laptopcomputer" : "moon.zzz.fill"
        } else {
            symbolName = "moon"
        }
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: sessionManager.l10n.appName)
        img?.isTemplate = true
        button.image = img

        let t = sessionManager.l10n
        if sessionManager.isRunning {
            let modeTxt = t.modeTitle(sessionManager.activeMode)
            let lidTxt = closedLid ? " · \(t.backpackBadge)" : ""
            button.toolTip = "\(t.appName) — \(t.runningBadge) (\(modeTxt)\(lidTxt))"
        } else if let cli = sessionManager.externalCLI {
            button.toolTip = "\(t.appName) — \(t.cliGuardingBanner(cli))"
        } else {
            button.toolTip = "\(t.appName) — \(t.idleBadge)"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        stopWatchingExternalCLI()
        stopDisplayTimer()
        sessionManager.stopSession(reason: .silent)
    }
}
