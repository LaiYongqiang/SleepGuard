import Foundation
import SleepGuardCore

enum StopReason {
    case manual
    case expired
    case lowBattery(Int)
    case silent
}

final class SessionManager: ObservableObject {
    @Published var config: SessionConfig
    @Published var isRunning: Bool = false
    @Published var isAuthorizing: Bool = false
    @Published var activeMode: GuardMode = .background
    @Published var activeClosedLid: Bool = false
    @Published var isIndefinite: Bool = false
    @Published var initialMinutes: Double = 240
    @Published var endDate: Date? = nil
    @Published var remainingSeconds: Int = 0
    @Published var errorMessage: String? = nil
    @Published var staleSleepDisabled: Bool = false
    @Published var showSettings: Bool = false
    @Published var showCustomInput: Bool = false
    @Published var customMinutesText: String = "90"
    @Published var launchAtLogin: Bool = false

    private let store: PreferencesStore
    private let caffeinateRunner = CaffeinateRunner()
    private let backpackGuard = BackpackGuard()
    private let powerMonitor = PowerMonitor()

    var onStateChange: ((_ active: Bool, _ closedLid: Bool) -> Void)?
    var onRequestClosePopover: (() -> Void)?

    var l10n: L10n {
        L10n(language: config.language)
    }

    init(store: PreferencesStore = PreferencesStore()) {
        self.store = store
        let loaded = store.load()
        self.config = loaded
        self.customMinutesText = loaded.customMinutes == loaded.customMinutes.rounded()
            ? "\(Int(loaded.customMinutes))"
            : String(format: "%.1f", loaded.customMinutes)
        self.launchAtLogin = LoginItemManager.isEnabled

        BackpackGuard.checkSleepDisabledAsync { [weak self] disabled in
            guard let self, !self.isRunning else { return }
            self.staleSleepDisabled = disabled
        }
    }

    func persistConfig() {
        store.save(config)
    }

    func selectMode(_ mode: GuardMode) {
        config.mode = mode
        persistConfig()
    }

    func selectDuration(_ minutes: Double) {
        config.durationMinutes = minutes
        showCustomInput = false
        persistConfig()
    }

    func applyCustomDuration() {
        let trimmed = customMinutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(trimmed), val > 0 else {
            return
        }
        config.customMinutes = val
        config.durationMinutes = val
        showCustomInput = false
        persistConfig()
    }

    func setLockOnStart(_ enabled: Bool) {
        config.lockOnStart = enabled
        persistConfig()
    }

    func setAllowClosedLid(_ enabled: Bool) {
        config.allowClosedLid = enabled
        persistConfig()
    }

    func setBatteryThreshold(_ percent: Int) {
        config.batteryThresholdPercent = percent
        persistConfig()
        if isRunning {
            startPowerWatch()
        }
    }

    func setLanguage(_ language: AppLanguage) {
        config.language = language
        persistConfig()
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            launchAtLogin = LoginItemManager.isEnabled
            errorMessage = nil
        } catch {
            launchAtLogin = LoginItemManager.isEnabled
            errorMessage = error.localizedDescription
        }
    }

    func refreshDisplayTick() {
        guard isRunning else { return }
        if isIndefinite {
            remainingSeconds = 0
            return
        }
        guard let endDate else { return }
        remainingSeconds = max(0, Int(endDate.timeIntervalSinceNow.rounded(.down)))
    }

    func startConfiguredSession() {
        guard !isAuthorizing else { return }
        errorMessage = nil
        persistConfig()

        let targetMode = config.mode
        let targetMinutes = config.durationMinutes
        let wantClosedLid = config.effectiveAllowClosedLid
        let wantLock = config.effectiveLockOnStart

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
        endDate = timeoutSec.map { Date().addingTimeInterval(TimeInterval($0)) }
        isRunning = true
        showCustomInput = false
        showSettings = false
        refreshDisplayTick()
        startPowerWatch()

        onStateChange?(true, closedLid)

        let durText = DurationFormatter.formatDuration(minutes, isChinese: l10n.isZh)
        let lidSuffix = closedLid ? (l10n.isZh ? " · 合盖保持唤醒" : " · Lid-Closed") : ""
        Notifier.send(title: l10n.notifStartedTitle, body: "\(l10n.modeTitle(mode)) · \(durText)\(lidSuffix)")

        if lockImmediately {
            ScreenLocker.lockScreen()
        }
        onRequestClosePopover?()
    }

    func switchRunningMode(to newMode: GuardMode) {
        guard isRunning, newMode != activeMode else { return }
        errorMessage = nil

        let remainingTimeout: Int?
        if isIndefinite {
            remainingTimeout = nil
        } else if let endDate {
            remainingTimeout = max(1, Int(endDate.timeIntervalSinceNow.rounded()))
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func extendSession(byMinutes addMinutes: Double = 30) {
        guard isRunning, !isIndefinite else { return }
        errorMessage = nil

        let currentLeft = max(0, endDate?.timeIntervalSinceNow ?? 0)
        let newTotalSeconds = max(1, Int((currentLeft + addMinutes * 60.0).rounded()))
        let newEndDate = Date().addingTimeInterval(TimeInterval(newTotalSeconds))

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

    func stopSession(reason: StopReason = .manual) {
        powerMonitor.stop()
        caffeinateRunner.stop()
        backpackGuard.disable()

        isRunning = false
        activeClosedLid = false
        endDate = nil
        remainingSeconds = 0
        onStateChange?(false, false)

        switch reason {
        case .manual:
            Notifier.send(title: l10n.notifStoppedTitle, body: l10n.notifStoppedBody)
        case .expired:
            Notifier.send(title: l10n.notifStoppedTitle, body: l10n.notifExpiredBody)
        case .lowBattery(let pct):
            Notifier.send(title: l10n.notifLowBatteryTitle, body: l10n.notifLowBatteryBody(pct))
        case .silent:
            break
        }
    }

    func restoreStaleSleepDisabled() {
        BackpackGuard.restoreNormalSleepAsync { [weak self] result in
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
        powerMonitor.start(thresholdPercent: config.batteryThresholdPercent) { [weak self] pct in
            guard let self, self.isRunning else { return }
            self.stopSession(reason: .lowBattery(pct))
        }
    }
}
