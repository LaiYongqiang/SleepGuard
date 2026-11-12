#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p .build/verify
DRIVER=".build/verify/verify_main.swift"
BIN=".build/verify/verify_runner"

cat > "$DRIVER" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

final class MockCaffeinateRunner: CaffeinateRunning {
    var isActive: Bool = false
    var shouldThrowOnStart = false
    var lastMode: GuardMode?
    var lastTimeout: Int?

    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws {
        if shouldThrowOnStart {
            throw NSError(domain: "MockCaffeinate", code: 1, userInfo: [NSLocalizedDescriptionKey: "spawn failed"])
        }
        isActive = true
        lastMode = mode
        lastTimeout = timeoutSeconds
    }

    func stop() {
        isActive = false
    }
}

final class MockBackpackGuard: BackpackGuarding {
    var enableCalls = 0
    var disableCalls = 0
    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        enableCalls += 1
        completion(.success(()))
    }
    func disable() { disableCalls += 1 }
    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) { completion(false) }
    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}

final class MockPowerMonitor: PowerMonitoring {
    var snapshot: PowerSnapshot? = PowerSnapshot(onBattery: false, percentage: 100)
    var eventHandler: ((PowerEvent) -> Void)?
    func currentPowerSnapshot() -> PowerSnapshot? { snapshot }
    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) { eventHandler = onEvent }
    func stop() { eventHandler = nil }
}

final class MockScreenLocker: ScreenLocking {
    var lockCount = 0
    func lockScreen() { lockCount += 1 }
}

final class MockNotifier: UserNotifying {
    var sent: [(String, String)] = []
    func preparePermissionIfNeeded() {}
    func send(title: String, body: String) { sent.append((title, body)) }
}

final class MockLoginItem: LoginItemControlling {
    var isEnabled: Bool = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@main
struct VerifyRunner {
    static func main() throws {
        // 1. CommandBuilder checks
        expect(
            CommandBuilder.caffeinateArguments(mode: .background, parentPID: 1234, timeoutSeconds: 14400) == ["-i", "-w", "1234", "-t", "14400"],
            "Background timed caffeinate args"
        )
        expect(
            CommandBuilder.caffeinateArguments(mode: .keepDisplay, parentPID: 5678, timeoutSeconds: nil) == ["-di", "-w", "5678"],
            "KeepDisplay indefinite caffeinate args"
        )
        expect(CommandBuilder.timeoutSeconds(forMinutes: 0) == nil, "Indefinite timeout returns nil")
        expect(CommandBuilder.timeoutSeconds(forMinutes: 240) == 14400, "240m -> 14400s")

        // 2. URLCommandParser & CLIParser checks
        let url = URL(string: "sleepskip://start?mode=display&minutes=90&lock=0")!
        expect(URLCommandParser.parse(url) == .start(mode: .keepDisplay, minutes: 90, lockOnStart: false, allowClosedLid: nil), "URL start parsing")
        expect(URLCommandParser.parse(URL(string: "sleepskip://stop")!) == .stop, "URL stop parsing")
        expect(CLIParser.parse(arguments: ["SleepSkip", "--display", "--lock", "--", "codex", "fix"]) == .runCommand(arguments: ["codex", "fix"], mode: .keepDisplay, lockOnFinish: true), "CLI command parsing")
        expect(CLIParser.parse(arguments: ["SleepSkip", "watch", "999"]) == .watchPID(pid: 999, mode: .background, lockOnFinish: false), "CLI watch PID parsing")

        // 2b. Regression: pass-through argv must not be hijacked by SleepSkip's own flags
        expect(CLIParser.parse(arguments: ["SleepSkip", "--", "codex", "--version"]) == .runCommand(arguments: ["codex", "--version"], mode: .background, lockOnFinish: false), "`-- codex --version` runs codex, not the version banner")
        expect(CLIParser.parse(arguments: ["SleepSkip", "--", "npm", "-v"]) == .runCommand(arguments: ["npm", "-v"], mode: .background, lockOnFinish: false), "`-- npm -v` passes through")
        expect(CLIParser.parse(arguments: ["SleepSkip", "--", "claude", "--help"]) == .runCommand(arguments: ["claude", "--help"], mode: .background, lockOnFinish: false), "`-- claude --help` passes through")
        expect(CLIParser.parse(arguments: ["SleepSkip", "--version"]) == .version, "Bare --version still reports version")
        expect(CLIParser.parse(arguments: ["SleepSkip", "--"]) == .help, "Dangling -- is not a command")

        // 2c. Regression: non-finite durations must never reach Int(_:)
        for raw in ["inf", "Infinity", "-inf", "1e999", "nan"] {
            if let v = Double(raw) {
                expect(CommandBuilder.timeoutSeconds(forMinutes: v) == nil, "\(raw) yields no timeout")
            }
        }
        expect(CommandBuilder.timeoutSeconds(forMinutes: 1e300) == CommandBuilder.timeoutSeconds(forMinutes: CommandBuilder.maxDurationMinutes), "finite overflow is clamped, not trapped")
        expect(CommandBuilder.sanitizeMinutes(.infinity) == nil, "infinity rejected")
        expect(CommandBuilder.sanitizeMinutes(.nan) == nil, "NaN rejected")
        expect(CommandBuilder.sanitizeMinutes(CommandBuilder.maxDurationMinutes * 10) == CommandBuilder.maxDurationMinutes, "over-long duration clamped")
        expect(DurationFormatter.formatDuration(.infinity, isChinese: false) == "Indefinite", "inf renders as Indefinite")
        expect(DurationFormatter.formatShortPreset(.nan, isChinese: true) == "永久", "NaN renders as indefinite preset")
        expect(URLCommandParser.parse(URL(string: "sleepskip://start?minutes=inf")!) == .start(mode: nil, minutes: nil, lockOnStart: nil, allowClosedLid: nil), "URL minutes=inf is dropped")
        expect(URLCommandParser.parse(URL(string: "sleepskip://start?minutes=1e300")!) == .start(mode: nil, minutes: CommandBuilder.maxDurationMinutes, lockOnStart: nil, allowClosedLid: nil), "URL minutes clamped")

        // 2d. Regression: a poisoned stored value must be sanitized on load
        let poisonSuite = "io.github.laiyongqiang.SleepSkip.poison.\(UUID().uuidString)"
        let poisonDefaults = UserDefaults(suiteName: poisonSuite)!
        poisonDefaults.set(Double.infinity, forKey: "sleepskip.durationMinutes")
        poisonDefaults.set(Double.nan, forKey: "sleepskip.customMinutes")
        let poisoned = PreferencesStore(defaults: poisonDefaults).load()
        poisonDefaults.removePersistentDomain(forName: poisonSuite)
        expect(poisoned.durationMinutes == 240 && poisoned.customMinutes == 90, "Poisoned prefs fall back to defaults")

        // 3. PreferencesStore round-trip
        let suiteName = "io.github.laiyongqiang.SleepSkip.verify.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        var cfg = store.load()
        expect(cfg.mode == .background && cfg.durationMinutes == 240 && cfg.lockOnStart && !cfg.stopOnUnplug, "Defaults match spec")
        expect(!cfg.autoFollowAgents, "Auto-follow is off by default")
        cfg.stopOnUnplug = true
        cfg.autoFollowAgents = true
        cfg.language = .en
        store.save(cfg)
        expect(store.load() == cfg, "Preferences persistence round-trip")

        // 4. SessionManager state machine
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let pwr = MockPowerMonitor()
        let lock = MockScreenLocker()
        let notif = MockNotifier()
        let login = MockLoginItem()

        let manager = SessionManager(
            store: store,
            caffeinateRunner: caf,
            backpackGuard: bag,
            powerMonitor: pwr,
            screenLocker: lock,
            notifier: notif,
            loginItem: login,
            nowProvider: { now },
            checkStaleSleepOnInit: false
        )
        var closeCount = 0
        var stateEvents = 0
        manager.onRequestClosePopover = { closeCount += 1 }
        manager.onStateChange = { _, _ in stateEvents += 1 }

        // Pre-flight unplug guard prevents launch & Touch ID
        pwr.snapshot = PowerSnapshot(onBattery: true, percentage: 50)
        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        expect(!manager.isRunning && bag.enableCalls == 0 && manager.errorMessage != nil, "Pre-flight unplug blocks launch before Touch ID")

        // KeepDisplay start does NOT close popover
        pwr.snapshot = PowerSnapshot(onBattery: false, percentage: 100)
        manager.setStopOnUnplug(false)
        manager.selectMode(.keepDisplay)
        manager.startConfiguredSession()
        expect(manager.isRunning && closeCount == 0 && lock.lockCount == 0 && notif.sent.isEmpty, "Non-locking start stays open without notification spam")

        // Extend + failed switch + language tooltip callback + wake reconcile
        now = now.addingTimeInterval(60)
        manager.extendSession(byMinutes: 30)
        expect(manager.remainingSeconds == 16140, "Extend +30m updates remaining seconds")

        caf.shouldThrowOnStart = true
        manager.switchRunningMode(to: .background)
        expect(manager.activeMode == .keepDisplay, "Failed mode switch keeps old mode")
        caf.shouldThrowOnStart = false
        manager.switchRunningMode(to: .background)
        expect(manager.activeMode == .background, "Mode switch preserves active session")

        let beforeLangEvents = stateEvents
        manager.setLanguage(.zhHans)
        expect(stateEvents > beforeLangEvents, "Language change triggers tooltip refresh")

        caf.isActive = false
        manager.reconcileOnWakeOrShow()
        expect(!manager.isRunning && notif.sent.count == 1, "Wake reconcile catches exited caffeinate and notifies once")

        // 4b. Auto-follow state machine
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = AgentActivityTracker(
            policy: AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 7200),
            nowProvider: { clock }
        )
        expect(tracker.evaluate() == .inactive, "Fresh tracker is inactive")
        tracker.recordActivity(sourceID: "claude-code")
        expect(tracker.shouldHoldAssertion(for: tracker.evaluate()), "Activity holds the assertion")
        clock = clock.addingTimeInterval(20)
        expect(tracker.evaluate().isHolding, "Quiet inside the window still holds")
        clock = clock.addingTimeInterval(40)
        if case .grace = tracker.evaluate() {
            expect(tracker.shouldHoldAssertion(for: tracker.evaluate()), "Grace period holds")
        } else {
            expect(false, "Past the window should enter grace")
        }
        clock = clock.addingTimeInterval(301)
        expect(tracker.evaluate() == .inactive, "Past the grace period releases")
        expect(!tracker.shouldHoldAssertion(for: tracker.evaluate()), "Released state does not hold")

        clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ceilingTracker = AgentActivityTracker(
            policy: AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 120),
            nowProvider: { clock }
        )
        for _ in 0..<10 {
            ceilingTracker.recordActivity(sourceID: "claude-code")
            clock = clock.addingTimeInterval(20)
        }
        expect(ceilingTracker.autoSessionExceeded(), "Hard ceiling is reached")
        expect(!ceilingTracker.shouldHoldAssertion(for: ceilingTracker.evaluate()), "Ceiling overrides activity")

        // Parallel sessions: any active source keeps the assertion.
        clock = Date(timeIntervalSince1970: 1_900_000_000)
        let parallel = AgentActivityTracker(
            policy: AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 7200),
            nowProvider: { clock }
        )
        parallel.recordActivity(sourceID: "claude-code")
        clock = clock.addingTimeInterval(10)
        parallel.recordActivity(sourceID: "codex")
        clock = clock.addingTimeInterval(25)
        if case .active(let agents, _) = parallel.evaluate() {
            expect(agents == ["codex"], "Only the still-active source is reported")
        } else {
            expect(false, "Parallel sessions should stay active")
        }

        // Default sources point at transcript directories under the home folder.
        let sources = AgentSource.defaults(homeDirectory: URL(fileURLWithPath: "/Users/example"))
        expect(sources.map(\.id) == ["claude-code", "codex"], "Default agent sources")
        expect(sources[0].path == "/Users/example/.claude/projects", "Claude transcript path")

        // 5. Live caffeinate -w lifecycle check
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["10"]
        try sentinel.run()

        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = CommandBuilder.caffeinateArguments(
            mode: .background,
            parentPID: sentinel.processIdentifier,
            timeoutSeconds: 30
        )
        try caffeinate.run()
        usleep(150_000)
        expect(caffeinate.isRunning, "caffeinate started and running")

        sentinel.terminate()
        sentinel.waitUntilExit()
        caffeinate.waitUntilExit()
        expect(!caffeinate.isRunning && caffeinate.terminationStatus == 0, "caffeinate auto-exits cleanly when watched PID terminates")

        print("ALL VERIFICATION CHECKS PASSED")
    }
}
SWIFT

swiftc -O Sources/SleepSkipCore/*.swift "$DRIVER" -o "$BIN"
"$BIN"
rm -rf .build/verify
