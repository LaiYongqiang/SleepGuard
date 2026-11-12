import Combine
import Foundation

public enum StopReason: Equatable, Sendable {
    case manual
    case expired
    case lowBattery(Int)
    case unplugged
    case silent
}

public protocol CaffeinateRunning: AnyObject {
    var isActive: Bool { get }
    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws
    func stop()
}

public protocol BackpackGuarding: AnyObject {
    func enable(completion: @escaping (Result<Void, Error>) -> Void)
    func disable()
    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void)
    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void)
}

public protocol PowerMonitoring: AnyObject {
    func currentPowerSnapshot() -> PowerSnapshot?
    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void)
    func stop()
}

public protocol ScreenLocking: AnyObject {
    func lockScreen()
}

public protocol UserNotifying: AnyObject {
    func preparePermissionIfNeeded()
    func send(title: String, body: String)
}

public protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public final class SessionManager: ObservableObject {
    @Published public var config: SessionConfig
    @Published public var isRunning: Bool = false
    @Published public var isAuthorizing: Bool = false
    @Published public var activeMode: GuardMode = .background
    @Published public var activeClosedLid: Bool = false
    @Published public var isIndefinite: Bool = false
    @Published public var initialMinutes: Double = 240
    @Published public var endDate: Date? = nil
    @Published public var remainingSeconds: Int = 0
    @Published public var errorMessage: String? = nil
    @Published public var staleSleepDisabled: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showCustomInput: Bool = false
    @Published public var customMinutesText: String = "90"
    @Published public var launchAtLogin: Bool = false
    @Published public var externalCLI: ExternalCLISession? = nil

    /// True while a detected agent is holding the assertion on the user's behalf.
    @Published public var isFollowingAgents: Bool = false
    /// Agents currently driving the automatic session, for display.
    @Published public var followingAgents: [String] = []
    /// True once an automatic session hit its hard ceiling; the next detection starts fresh.
    @Published public var autoFollowLimitReached: Bool = false
    /// Set after the user stops a session while agents are still writing, so the Mac does not
    /// immediately wake itself again. Cleared once all agents have gone quiet.
    private var autoFollowSuppressed = false

    private let store: PreferencesStore
    private let caffeinateRunner: CaffeinateRunning
    private let backpackGuard: BackpackGuarding
    private let powerMonitor: PowerMonitoring
    private let screenLocker: ScreenLocking
    private let notifier: UserNotifying
    private let loginItem: LoginItemControlling
    private let nowProvider: () -> Date
    /// Exposed so the host can hand it to the FSEvents monitor.
    public let agentTracker: AgentActivityTracker

    public var onStateChange: ((_ active: Bool, _ closedLid: Bool) -> Void)?
    public var onRequestClosePopover: (() -> Void)?
    /// Called when auto-follow starts or stops so the host can start/stop the FSEvents monitor.
    public var onAutoFollowToggled: ((_ enabled: Bool) -> Void)?

    public var l10n: L10n {
        L10n(language: config.language)
    }

    public var isEffectivelyActive: Bool {
        isRunning || externalCLI != nil
    }

    public var isAutoFollowEnabled: Bool {
        config.autoFollowAgents
    }

    /// Starts or stops watching for agent activity. The monitor itself is owned by the host
    /// so the core stays free of FSEvents; this only flips the preference and notifies.
    public func setAutoFollowEnabled(_ enabled: Bool) {
        guard config.autoFollowAgents != enabled else { return }
        config.autoFollowAgents = enabled
        autoFollowSuppressed = false
        persistConfig()
        if !enabled {
            endAutoFollow()
        }
        onAutoFollowToggled?(enabled)
        onStateChange?(isEffectivelyActive, activeClosedLid)
    }

    /// Called by the monitor on every display-relevant transition.
    public func handleAgentActivity(_ state: AgentActivityState) {
        guard config.autoFollowAgents else { return }

        // Re-arm only after the agents have actually gone quiet.
        if autoFollowSuppressed {
            if state == .inactive { autoFollowSuppressed = false }
            return
        }

        // A manual session always wins; auto-follow never overrides it.
        guard !isRunning else { return }

        if agentTracker.shouldHoldAssertion(for: state) {
            switch state {
            case .active(let agents, _):
                followingAgents = agents
            case .grace:
                break
            case .inactive:
                break
            }
            if !isFollowingAgents {
                beginAutoFollow()
            }
        } else if isFollowingAgents {
            endAutoFollow()
        }
    }

    private func beginAutoFollow() {
        guard !isRunning else { return }
        // Auto-follow is background-only and never enables closed-lid mode: that stays manual.
        let timeout = CommandBuilder.timeoutSeconds(forMinutes: config.durationMinutes)
        do {
            try caffeinateRunner.start(mode: .background, timeoutSeconds: timeout) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        activeMode = .background
        activeClosedLid = false
        isIndefinite = (timeout == nil)
        initialMinutes = config.durationMinutes
        endDate = timeout.map { nowProvider().addingTimeInterval(TimeInterval($0)) }
        isFollowingAgents = true
        autoFollowLimitReached = false
        isRunning = true
        startPowerWatch()
        onStateChange?(isEffectivelyActive, false)
    }

    private func endAutoFollow() {
        guard isFollowingAgents else { return }
        isFollowingAgents = false
        followingAgents = []
        if isRunning {
            stopSession(reason: .silent)
        }
        onStateChange?(isEffectivelyActive, false)
    }

    /// The hard ceiling was hit: release now and require a fresh detection before holding again.
    public func handleAutoFollowLimitReached() {
        autoFollowLimitReached = true
        endAutoFollow()
        notifier.send(title: l10n.notifAutoFollowLimitTitle, body: l10n.notifAutoFollowLimitBody)
    }

    public func resetAutoFollowLimit() {
        autoFollowLimitReached = false
        agentTracker.reset()
    }

    public init(
        store: PreferencesStore = PreferencesStore(),
        caffeinateRunner: CaffeinateRunning,
        backpackGuard: BackpackGuarding,
        powerMonitor: PowerMonitoring,
        screenLocker: ScreenLocking,
        notifier: UserNotifying,
        loginItem: LoginItemControlling,
        nowProvider: @escaping () -> Date = { Date() },
        agentPolicy: AgentActivityPolicy = .default,
        checkStaleSleepOnInit: Bool = true
    ) {
        self.store = store
        self.caffeinateRunner = caffeinateRunner
        self.backpackGuard = backpackGuard
        self.powerMonitor = powerMonitor
        self.screenLocker = screenLocker
        self.notifier = notifier
        self.loginItem = loginItem
        self.nowProvider = nowProvider
        self.agentTracker = AgentActivityTracker(policy: agentPolicy, nowProvider: nowProvider)

        let loaded = store.load()
        self.config = loaded
        self.customMinutesText = loaded.customMinutes == loaded.customMinutes.rounded()
            ? "\(Int(loaded.customMinutes))"
            : String(format: "%.1f", loaded.customMinutes)
        self.launchAtLogin = loginItem.isEnabled

        if checkStaleSleepOnInit {
            backpackGuard.checkSleepDisabledAsync { [weak self] disabled in
                guard let self, !self.isRunning else { return }
                self.staleSleepDisabled = disabled
            }
        }
    }

    public func persistConfig() {
        store.save(config)
    }

    public func selectMode(_ mode: GuardMode) {
        config.mode = mode
        persistConfig()
    }

    public func selectDuration(_ minutes: Double) {
        config.durationMinutes = minutes
        showCustomInput = false
        persistConfig()
    }

    public func applyCustomDuration() {
        let trimmed = customMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        // `Double("inf")` and `Double("1e999")` parse to infinity; sanitize before persisting so a
        // bad value can never reach Int(_:) in the countdown or the caffeinate timeout.
        guard let parsed = Double(trimmed), let val = CommandBuilder.sanitizeMinutes(parsed) else {
            errorMessage = l10n.invalidDurationError(CommandBuilder.maxDurationMinutes)
            return
        }
        config.customMinutes = val
        config.durationMinutes = val
        showCustomInput = false
        errorMessage = nil
        persistConfig()
    }

    public func setLockOnStart(_ enabled: Bool) {
        config.lockOnStart = enabled
        persistConfig()
    }

    public func setAllowClosedLid(_ enabled: Bool) {
        config.allowClosedLid = enabled
        persistConfig()
    }

    public func setBatteryThreshold(_ percent: Int) {
        config.batteryThresholdPercent = percent
        persistConfig()
        if isRunning {
            startPowerWatch()
        }
    }

    public func setStopOnUnplug(_ enabled: Bool) {
        config.stopOnUnplug = enabled
        persistConfig()
        if isRunning {
            startPowerWatch()
        }
    }

    public func setLanguage(_ language: AppLanguage) {
        config.language = language
        persistConfig()
        onStateChange?(isEffectivelyActive, activeClosedLid)
    }

    public func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            launchAtLogin = loginItem.isEnabled
            errorMessage = nil
        } catch {
            launchAtLogin = loginItem.isEnabled
            errorMessage = error.localizedDescription
        }
    }

    public func refreshDisplayTick() {
        guard isRunning else { return }
        if isIndefinite {
            remainingSeconds = 0
            return
        }
        guard let endDate else { return }
        remainingSeconds = max(0, Int(endDate.timeIntervalSince(nowProvider()).rounded(.down)))
    }

    public func reconcileOnWakeOrShow() {
        guard isRunning else { return }
        if !caffeinateRunner.isActive {
            stopSession(reason: .expired)
            return
        }
        refreshDisplayTick()
    }

    public func setExternalCLISession(_ session: ExternalCLISession?) {
        externalCLI = session
        onStateChange?(isEffectivelyActive, activeClosedLid)
    }

    public func startConfiguredSession() {
        guard !isAuthorizing else { return }
        errorMessage = nil
        persistConfig()

        if let snapshot = powerMonitor.currentPowerSnapshot(), snapshot.onBattery {
            if config.stopOnUnplug {
                errorMessage = l10n.unpluggedBlockedError
                return
            }
            if config.batteryThresholdPercent > 0,
               let pct = snapshot.percentage,
               pct <= config.batteryThresholdPercent {
                errorMessage = l10n.lowBatteryBlockedError(current: pct, threshold: config.batteryThresholdPercent)
                return
            }
        }

        let targetMode = config.mode
        let targetMinutes = config.durationMinutes
        let wantClosedLid = config.effectiveAllowClosedLid
        let wantLock = config.effectiveLockOnStart

        if targetMinutes > 0 || config.batteryThresholdPercent > 0 || config.stopOnUnplug {
            notifier.preparePermissionIfNeeded()
        }

        if wantClosedLid {
            isAuthorizing = true
            backpackGuard.enable { [weak self] result in
                guard let self else { return }
                self.isAuthorizing = false
                switch result {
                case .success:
                    self.staleSleepDisabled = false
                    self.launchCaffeinate(mode: targetMode, minutes: targetMinutes, closedLid: true, lockImmediately: wantLock)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        } else {
            backpackGuard.disable()
            launchCaffeinate(mode: targetMode, minutes: targetMinutes, closedLid: false, lockImmediately: wantLock)
        }
    }

    private func launchCaffeinate(mode: GuardMode, minutes: Double, closedLid: Bool, lockImmediately: Bool) {
        let timeoutSec = CommandBuilder.timeoutSeconds(forMinutes: minutes)

        do {
            try caffeinateRunner.start(mode: mode, timeoutSeconds: timeoutSec) { [weak self] in
                self?.handleCaffeinateExited()
            }
        } catch {
            if closedLid {
                backpackGuard.disable()
            }
            errorMessage = error.localizedDescription
            return
        }

        activeMode = mode
        activeClosedLid = closedLid
        isIndefinite = (timeoutSec == nil)
        initialMinutes = minutes
        endDate = timeoutSec.map { nowProvider().addingTimeInterval(TimeInterval($0)) }
        isRunning = true
        showCustomInput = false
        showSettings = false
        refreshDisplayTick()
        startPowerWatch()

        onStateChange?(isEffectivelyActive, closedLid)

        if lockImmediately {
            onRequestClosePopover?()
            screenLocker.lockScreen()
        }
    }

    public func switchRunningMode(to newMode: GuardMode) {
        guard isRunning, newMode != activeMode else { return }
        errorMessage = nil

        let remainingTimeout: Int?
        if isIndefinite {
            remainingTimeout = nil
        } else if let endDate {
            remainingTimeout = max(1, Int(endDate.timeIntervalSince(nowProvider()).rounded()))
        } else {
            remainingTimeout = nil
        }

        do {
            try caffeinateRunner.start(mode: newMode, timeoutSeconds: remainingTimeout) { [weak self] in
                self?.handleCaffeinateExited()
            }
            activeMode = newMode
            config.mode = newMode
            persistConfig()
            onStateChange?(isEffectivelyActive, activeClosedLid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func extendSession(byMinutes addMinutes: Double = 30) {
        guard isRunning, !isIndefinite else { return }
        errorMessage = nil

        let currentLeft = max(0, endDate?.timeIntervalSince(nowProvider()) ?? 0)
        let newTotalSeconds = max(1, Int((currentLeft + addMinutes * 60.0).rounded()))
        let newEndDate = nowProvider().addingTimeInterval(TimeInterval(newTotalSeconds))

        do {
            try caffeinateRunner.start(mode: activeMode, timeoutSeconds: newTotalSeconds) { [weak self] in
                self?.handleCaffeinateExited()
            }
            endDate = newEndDate
            initialMinutes += addMinutes
            refreshDisplayTick()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stopSession(reason: StopReason = .manual) {
        powerMonitor.stop()
        caffeinateRunner.stop()
        backpackGuard.disable()

        // A user-initiated stop while agents are still writing should stay stopped; only a fresh
        // quiet period re-arms auto-follow.
        if reason == .manual, config.autoFollowAgents {
            autoFollowSuppressed = true
        }
        isFollowingAgents = false
        followingAgents = []
        isRunning = false
        activeClosedLid = false
        endDate = nil
        remainingSeconds = 0
        onStateChange?(isEffectivelyActive, false)

        switch reason {
        case .manual, .silent:
            break
        case .expired:
            notifier.send(title: l10n.notifStoppedTitle, body: l10n.notifExpiredBody)
        case .lowBattery(let pct):
            notifier.send(title: l10n.notifLowBatteryTitle, body: l10n.notifLowBatteryBody(pct))
        case .unplugged:
            notifier.send(title: l10n.notifUnpluggedTitle, body: l10n.notifUnpluggedBody)
        }
    }

    public func applyURLCommand(_ command: URLCommand) {
        switch command {
        case .start(let mode, let minutes, let lockOnStart, let allowClosedLid):
            if let mode { config.mode = mode }
            if let minutes { config.durationMinutes = minutes }
            if let lockOnStart { config.lockOnStart = lockOnStart }
            if let allowClosedLid { config.allowClosedLid = allowClosedLid }
            persistConfig()
            if !isRunning {
                startConfiguredSession()
            } else if let mode, mode != activeMode {
                switchRunningMode(to: mode)
            }
        case .stop:
            if isRunning {
                stopSession(reason: .manual)
            }
        case .toggle:
            if isRunning {
                stopSession(reason: .manual)
            } else {
                startConfiguredSession()
            }
        case .lock:
            onRequestClosePopover?()
            screenLocker.lockScreen()
        case .open:
            break
        }
    }

    public func restoreStaleSleepDisabled() {
        backpackGuard.restoreNormalSleepAsync { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.staleSleepDisabled = false
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCaffeinateExited() {
        guard isRunning else { return }
        stopSession(reason: .expired)
    }

    private func startPowerWatch() {
        powerMonitor.start(
            thresholdPercent: config.batteryThresholdPercent,
            stopOnUnplug: config.stopOnUnplug
        ) { [weak self] event in
            guard let self, self.isRunning else { return }
            switch event {
            case .lowBattery(let pct):
                self.stopSession(reason: .lowBattery(pct))
            case .unplugged:
                self.stopSession(reason: .unplugged)
            }
        }
    }
}
