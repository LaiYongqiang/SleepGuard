import Cocoa
import Darwin
import Foundation
import SleepGuardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let openPopoverNotification = Notification.Name("io.github.laiyongqiang.SleepGuard.OpenPopover")

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var displayTimer: Timer?
    private var keyMonitor: Any?
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?

    let sessionManager = SessionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        setupSignalHandlers()
        setupDistributedNotifications()
        setupStatusItem()
        setupPopover()
        setupKeyboardShortcuts()

        sessionManager.onStateChange = { [weak self] active, closedLid in
            self?.updateStatusItemAppearance(active: active, closedLid: closedLid)
        }
        sessionManager.onRequestClosePopover = { [weak self] in
            self?.closePopover()
        }

        updateStatusItemAppearance(active: sessionManager.isRunning, closedLid: sessionManager.activeClosedLid)

        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.showPopover()
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
                    Self.openPopoverNotification,
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
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalOpenRequest),
            name: Self.openPopoverNotification,
            object: nil
        )
    }

    @objc private func handleExternalOpenRequest() {
        DispatchQueue.main.async {
            self.showPopover()
        }
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

        let rootView = SleepGuardPopoverView(manager: sessionManager)
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
        sessionManager.refreshDisplayTick()
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
        ScreenLocker.lockScreen()
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
        sessionManager.refreshDisplayTick()
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
            symbolName = closedLid ? "lock.laptopcomputer" : "cup.and.saucer.fill"
        } else {
            symbolName = "cup.and.saucer"
        }
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: sessionManager.l10n.appName)
        img?.isTemplate = true
        button.image = img

        let t = sessionManager.l10n
        if active {
            let modeTxt = t.modeTitle(sessionManager.activeMode)
            let lidTxt = closedLid ? " · \(t.backpackBadge)" : ""
            button.toolTip = "\(t.appName) — \(t.runningBadge) (\(modeTxt)\(lidTxt))"
        } else {
            button.toolTip = "\(t.appName) — \(t.idleBadge)"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        stopDisplayTimer()
        sessionManager.stopSession(reason: .silent)
    }
}
