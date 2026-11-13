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
    var startCount = 0
    var stopCount = 0

    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws {
        if shouldThrowOnStart {
            throw NSError(domain: "MockCaffeinate", code: 1, userInfo: [NSLocalizedDescriptionKey: "spawn failed"])
        }
        startCount += 1
        isActive = true
        lastMode = mode
        lastTimeout = timeoutSeconds
    }

    func stop() {
        stopCount += 1
        isActive = false
    }
}

final class MockBackpackGuard: BackpackGuarding {
    var enableCalls = 0
    var disableCalls = 0
    /// When true, `enable` withholds its completion so a test can act while authorization is
    /// still pending — the state a real Touch ID prompt sits in for several seconds.
    var deferCompletion = false
    private var pending: ((Result<Void, Error>) -> Void)?

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        enableCalls += 1
        if deferCompletion {
            pending = completion
        } else {
            completion(.success(()))
        }
    }

    /// Delivers a withheld completion, as the authorization dialog eventually would.
    func finishPending() {
        pending?(.success(()))
        pending = nil
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

        // The lid guard runs as a standalone script, not through `do shell script`, whose
        // output pipe a backgrounded child would keep open and block on.
        let lidScript = CommandBuilder.closedLidWatchScript(watchPID: 4242)
        expect(lidScript.hasPrefix("#!/bin/sh"), "Lid guard is a runnable script")
        expect(lidScript.contains("/usr/bin/pmset -a disablesleep 1 || exit 1"), "Guard enables lid-close sleep")
        expect(lidScript.contains("trap '/usr/bin/pmset -a disablesleep 0' EXIT INT TERM"), "Guard restores sleep on exit")
        expect(lidScript.contains("/usr/bin/caffeinate -i -w 4242"), "Guard watches the sentinel pid")
        expect(!lidScript.contains("&\n"), "Guard does not background a child that would hold the pipe")

        // Regression: the guard lives under "~/Library/Application Support/...", which contains a
        // space. Unquoted, `do shell script` split the path, the script never ran, and the command
        // still exited 0 — a silent no-op the UI reported as success.
        let spacedScript = "/Users/me/Library/Application Support/SleepSkip/lid-guard.sh"
        let launch = CommandBuilder.closedLidLaunchScript(scriptPath: spacedScript, pidPath: spacedScript + ".pid")
        expect(launch.contains("'\(spacedScript)'"), "Launch command single-quotes the script path")
        expect(launch.contains("'\(spacedScript).pid'"), "Launch command single-quotes the pid path")
        expect(!launch.contains("/bin/sh \(spacedScript) "), "Script path is not left bare")
        expect(CommandBuilder.shellSingleQuoted("/tmp/it's") == "'/tmp/it'\\''s'", "Embedded apostrophes are escaped")
        expect(CommandBuilder.shellSingleQuoted("") == "''", "Empty path still quoted")

        // The quoted command must actually run the script, not merely look right.
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SleepSkip Verify \(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let marker = dir.appendingPathComponent("ran.txt")
            let guardURL = dir.appendingPathComponent("lid-guard.sh")
            try "#!/bin/sh\necho ok > \(CommandBuilder.shellSingleQuoted(marker.path))\n"
                .write(to: guardURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: guardURL.path)

            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", CommandBuilder.closedLidLaunchScript(scriptPath: guardURL.path, pidPath: guardURL.path + ".pid")]
            try shell.run()
            shell.waitUntilExit()

            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                usleep(50_000)
            }
            expect(FileManager.default.fileExists(atPath: marker.path), "Quoted launch command really runs the guard")
        }

        // Regression: the guard's pid check never matched. `proc_pidpath` reports the
        // interpreter (/bin/bash), so `hasSuffix("lid-guard.sh")` was always false and a
        // leftover `disablesleep 1` guard was never terminated on relaunch.
        do {
            // Synthetic KERN_PROCARGS2 buffer: argc, exe path, NUL padding, argv.
            func procargs(_ argc: Int32, _ exe: String, _ args: [String]) -> [UInt8] {
                var bytes = withUnsafeBytes(of: argc) { Array($0) }
                bytes += Array(exe.utf8) + [0]
                bytes += [0, 0, 0]
                for arg in args { bytes += Array(arg.utf8) + [0] }
                return bytes
            }

            let guardPath = "/Users/me/Library/Application Support/SleepSkip/lid-guard.sh"
            let buf = procargs(2, "/bin/bash", ["/bin/sh", guardPath])
            let parsed = ProcessArguments.parse(buf, count: buf.count)
            expect(parsed == ["/bin/sh", guardPath], "KERN_PROCARGS2 argv is parsed past the executable path")
            expect(parsed.contains { $0.contains("lid-guard.sh") }, "Guard script is visible in argv")
            expect(!ProcessArguments.parse(procargs(1, "/bin/bash", ["/bin/sh"]), count: 64).contains { $0.contains("lid-guard.sh") }, "Unrelated sh process is not mistaken for the guard")
            expect(ProcessArguments.parse([], count: 0).isEmpty, "Empty buffer yields no arguments")
            expect(ProcessArguments.parse([0, 0, 0, 0], count: 4).isEmpty, "argc=0 yields no arguments")

            // End-to-end: read a live process's argv through the real sysctl path.
            // `/bin/sh -c "sleep 5"` execs into `sleep`, losing the script text from argv, so
            // use an interpreter that stays resident: `sh -s` reads stdin and keeps its argv.
            let liveInput = Pipe()
            let live = Process()
            live.executableURL = URL(fileURLWithPath: "/bin/sh")
            live.arguments = ["-s", "sleepskip-verify-marker"]
            live.standardInput = liveInput
            try live.run()
            usleep(300_000)
            let liveArgs = ProcessArguments.read(pid: live.processIdentifier)
            expect(liveArgs.contains("sleepskip-verify-marker"), "Live process argv is readable")
            live.terminate()
            live.waitUntilExit()
        }

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
        // A typo used to silently launch the GUI; it must fail visibly instead.
        expect(CLIParser.parse(arguments: ["SleepSkip", "start"]) == .invalid("unknown argument 'start'"), "Unknown subcommand is rejected")
        expect(CLIParser.parse(arguments: ["SleepSkip", "watch"]) == .invalid("watch needs a numeric pid"), "watch without a pid is rejected")
        expect(CLIParser.parse(arguments: ["SleepSkip", "--open"]) == .gui(openPopover: true), "Bare --open still launches the GUI")

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
        expect(cfg.autoFollowAgents, "Auto-follow is on by default")
        cfg.stopOnUnplug = true
        cfg.autoFollowAgents = false
        cfg.language = .en
        store.save(cfg)
        expect(store.load() == cfg, "Preferences persistence round-trip")
        expect(store.load().autoFollowAgents == false, "An explicit opt-out survives reload")

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

        // Regression: stopping while Touch ID was pending launched the session anyway, because
        // the completion only compared its token and `stopSession` never invalidated it.
        do {
            let cafA = MockCaffeinateRunner()
            let bagA = MockBackpackGuard()
            let suiteA = "io.github.laiyongqiang.SleepSkip.authrace.\(UUID().uuidString)"
            let defaultsA = UserDefaults(suiteName: suiteA)!
            defer { defaultsA.removePersistentDomain(forName: suiteA) }
            let smA = SessionManager(
                store: PreferencesStore(defaults: defaultsA),
                caffeinateRunner: cafA,
                backpackGuard: bagA,
                powerMonitor: MockPowerMonitor(),
                screenLocker: MockScreenLocker(),
                notifier: MockNotifier(),
                loginItem: MockLoginItem(),
                nowProvider: { Date(timeIntervalSince1970: 2_300_000_000) },
                checkStaleSleepOnInit: false
            )
            bagA.deferCompletion = true
            smA.setAllowClosedLid(true)
            smA.startConfiguredSession()
            expect(smA.isAuthorizing && bagA.enableCalls == 1, "Authorization is pending")
            smA.stopSession(reason: .manual)
            expect(!smA.isAuthorizing, "Stop clears the pending authorization")
            // The dialog now returns, seconds after the user already stopped.
            bagA.finishPending()
            expect(!smA.isRunning && cafA.startCount == 0, "A stopped authorization does not launch a session")
        }

        // 3b. Rename migration: an upgrade must not lose settings
        let newSuite = "io.github.laiyongqiang.SleepSkip.migrate.\(UUID().uuidString)"
        let oldSuite = "io.github.laiyongqiang.SleepGuard.migrate.\(UUID().uuidString)"
        let newDefaults = UserDefaults(suiteName: newSuite)!
        let oldDefaults = UserDefaults(suiteName: oldSuite)!
        oldDefaults.set("keepDisplay", forKey: "sleepguard.mode")
        oldDefaults.set(90.0, forKey: "sleepguard.durationMinutes")
        oldDefaults.set(false, forKey: "sleepguard.lockOnStart")
        oldDefaults.set("en", forKey: "sleepguard.language")
        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        let migrated = PreferencesStore(defaults: newDefaults).load()
        expect(migrated.mode == .keepDisplay, "Legacy mode migrates")
        expect(migrated.durationMinutes == 90, "Legacy duration migrates")
        expect(migrated.lockOnStart == false, "Legacy lock preference migrates")
        expect(migrated.language == .en, "Legacy language migrates")

        let freshSuite = "io.github.laiyongqiang.SleepSkip.existing.\(UUID().uuidString)"

        // Migration is one-shot and never overwrites settings the new domain already has.
        oldDefaults.set("background", forKey: "sleepguard.mode")
        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        expect(PreferencesStore(defaults: newDefaults).load().mode == .keepDisplay, "Migration does not run twice")

        let freshDefaults = UserDefaults(suiteName: freshSuite)!
        freshDefaults.set("background", forKey: "sleepskip.mode")
        freshDefaults.set(30.0, forKey: "sleepskip.durationMinutes")
        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: freshDefaults, legacyDefaults: oldDefaults)
        expect(PreferencesStore(defaults: freshDefaults).load().mode == .background, "Existing settings are not overwritten")
        for suite in [newSuite, oldSuite, freshSuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

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

        // Regression: hitting the ceiling must not disable auto-follow permanently.
        ceilingTracker.restartSessionWindow()
        ceilingTracker.recordActivity(sourceID: "claude-code")
        expect(!ceilingTracker.autoSessionExceeded(), "Restarting the window clears the ceiling")
        expect(ceilingTracker.shouldHoldAssertion(for: ceilingTracker.evaluate()), "Following resumes after a restart")

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

        // Regression: a manual stop must not be immediately undone by auto-follow.
        clock = Date(timeIntervalSince1970: 2_000_000_000)
        let caf2 = MockCaffeinateRunner()
        let sm = SessionManager(
            store: store,
            caffeinateRunner: caf2,
            backpackGuard: MockBackpackGuard(),
            powerMonitor: MockPowerMonitor(),
            screenLocker: MockScreenLocker(),
            notifier: MockNotifier(),
            loginItem: MockLoginItem(),
            nowProvider: { clock },
            checkStaleSleepOnInit: false
        )
        sm.setAutoFollowEnabled(true)
        sm.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(sm.isFollowingAgents && sm.isRunning, "Auto-follow engages on activity")
        // Regression: the panel read 00:00:00 because `remainingSeconds` was never computed.
        expect(sm.remainingSeconds > 0, "Auto-follow populates the countdown immediately")
        expect(sm.endDate != nil, "Auto-follow sets an end date")
        sm.stopSession(reason: .manual)
        expect(!sm.isFollowingAgents && !sm.isRunning, "Manual stop ends the automatic session")
        sm.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(!sm.isRunning, "Activity right after a manual stop does not revive the session")
        sm.handleAgentActivity(.inactive)
        sm.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(sm.isFollowingAgents && sm.isRunning, "A fresh quiet-then-active cycle re-arms auto-follow")
        sm.setAutoFollowEnabled(false)
        expect(!sm.isRunning && !sm.isFollowingAgents, "Disabling auto-follow releases everything")

        // Regression: auto-follow never released. `beginAutoFollow` sets `isRunning`, so guarding
        // on `isRunning` alone swallowed every later transition, including `.inactive`.
        clock = Date(timeIntervalSince1970: 2_100_000_000)
        let caf3 = MockCaffeinateRunner()
        let sm2 = SessionManager(
            store: store,
            caffeinateRunner: caf3,
            backpackGuard: MockBackpackGuard(),
            powerMonitor: MockPowerMonitor(),
            screenLocker: MockScreenLocker(),
            notifier: MockNotifier(),
            loginItem: MockLoginItem(),
            nowProvider: { clock },
            checkStaleSleepOnInit: false
        )
        sm2.setAutoFollowEnabled(true)
        sm2.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(sm2.isRunning, "Auto-follow starts on activity")
        sm2.handleAgentActivity(.inactive)
        expect(!sm2.isRunning && !sm2.isFollowingAgents, "Auto-follow releases once agents go quiet")

        // A manual session still wins: auto-follow must not launch over it, nor release it.
        sm2.startConfiguredSession()
        expect(sm2.isRunning, "Manual session starts")
        let manualStarts = caf3.startCount
        sm2.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(caf3.startCount == manualStarts && !sm2.isFollowingAgents, "Auto-follow does not relaunch a manual session")
        sm2.handleAgentActivity(.inactive)
        expect(sm2.isRunning, "A manual session survives agents going quiet")
        sm2.stopSession(reason: .manual)

        // Regression: the 2h ceiling used to release and re-arm within a second, so a busy agent
        // was held all night. It must stay released until the agents actually go quiet.
        clock = Date(timeIntervalSince1970: 2_200_000_000)
        let caf4 = MockCaffeinateRunner()
        let sm3 = SessionManager(
            store: store,
            caffeinateRunner: caf4,
            backpackGuard: MockBackpackGuard(),
            powerMonitor: MockPowerMonitor(),
            screenLocker: MockScreenLocker(),
            notifier: MockNotifier(),
            loginItem: MockLoginItem(),
            nowProvider: { clock },
            checkStaleSleepOnInit: false
        )
        sm3.setAutoFollowEnabled(true)
        sm3.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(sm3.isRunning, "Ceiling test: session starts")
        sm3.handleAutoFollowLimitReached()
        expect(!sm3.isRunning, "Ceiling releases the assertion")
        sm3.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(!sm3.isRunning, "Ceiling holds while the agent keeps writing")
        sm3.handleAgentActivity(.inactive)
        sm3.handleAgentActivity(.active(agents: ["claude-code"], lastActivity: clock))
        expect(sm3.isRunning, "A fresh quiet-then-active cycle resumes after the ceiling")
        sm3.setAutoFollowEnabled(false)

        // Default sources point at transcript directories under the home folder.
        let sources = AgentSource.defaults(homeDirectory: URL(fileURLWithPath: "/Users/example"))
        expect(sources.map(\.id) == ["claude-code", "codex", "dsh"], "Default agent sources")
        expect(sources[0].path == "/Users/example/.claude/projects", "Claude transcript path")
        expect(sources[2].path == "/Users/example/.dsh/sessions", "DSH transcript path")

        // Per-source transcript extensions: DSH compresses its transcripts.
        let dsh = sources[2]
        expect(dsh.matches(filePath: "/Users/example/.dsh/sessions/p/session.v4.jsonl.zstd"), "DSH .zstd transcripts match")
        expect(!sources[0].matches(filePath: "/Users/example/.claude/projects/p/session.v4.jsonl.zstd"), "Claude ignores .zstd")
        expect(sources[0].matches(filePath: "/Users/example/.claude/projects/p/s.jsonl"), "Claude matches .jsonl")
        expect(!dsh.matches(filePath: "/Users/example/.dsh/sessions-old/s.jsonl"), "Prefix collision rejected")

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
