#if canImport(XCTest)
import Foundation
import XCTest
@testable import SleepSkipCore

private final class MockCaffeinateRunner: CaffeinateRunning {
    var isActive: Bool = false
    var shouldThrowOnStart = false
    var startCount = 0
    var stopCount = 0
    var lastMode: GuardMode?
    var lastTimeout: Int?
    var exitCallback: (() -> Void)?

    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws {
        if shouldThrowOnStart {
            throw NSError(domain: "MockCaffeinate", code: 1, userInfo: [NSLocalizedDescriptionKey: "spawn failed"])
        }
        startCount += 1
        isActive = true
        lastMode = mode
        lastTimeout = timeoutSeconds
        exitCallback = onUnexpectedExit
    }

    func stop() {
        stopCount += 1
        isActive = false
    }
}

private final class MockBackpackGuard: BackpackGuarding {
    var enableCalls = 0
    var disableCalls = 0
    var shouldFailEnable = false

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        enableCalls += 1
        if shouldFailEnable {
            completion(.failure(NSError(domain: "MockBackpack", code: -1, userInfo: [NSLocalizedDescriptionKey: "auth cancelled"])))
        } else {
            completion(.success(()))
        }
    }

    func disable() {
        disableCalls += 1
    }

    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) {
        completion(false)
    }

    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

private final class MockPowerMonitor: PowerMonitoring {
    var snapshot: PowerSnapshot? = PowerSnapshot(onBattery: false, percentage: 100)
    var startedThreshold: Int = 0
    var startedStopOnUnplug: Bool = false
    var eventHandler: ((PowerEvent) -> Void)?

    func currentPowerSnapshot() -> PowerSnapshot? {
        snapshot
    }

    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) {
        startedThreshold = thresholdPercent
        startedStopOnUnplug = stopOnUnplug
        eventHandler = onEvent
    }

    func stop() {
        eventHandler = nil
    }
}

private final class MockScreenLocker: ScreenLocking {
    var lockCount = 0
    func lockScreen() { lockCount += 1 }
}

private final class MockNotifier: UserNotifying {
    var prepareCount = 0
    var sent: [(String, String)] = []
    func preparePermissionIfNeeded() { prepareCount += 1 }
    func send(title: String, body: String) { sent.append((title, body)) }
}

private final class MockLoginItem: LoginItemControlling {
    var isEnabled: Bool = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

final class SleepSkipCoreTests: XCTestCase {
    func testCommandBuilderBuildsBackgroundAndKeepDisplayArguments() {
        let bg = CommandBuilder.caffeinateArguments(mode: .background, parentPID: 1234, timeoutSeconds: 14400)
        XCTAssertEqual(bg, ["-i", "-w", "1234", "-t", "14400"])

        let disp = CommandBuilder.caffeinateArguments(mode: .keepDisplay, parentPID: 5678, timeoutSeconds: nil)
        XCTAssertEqual(disp, ["-di", "-w", "5678"])

        XCTAssertNil(CommandBuilder.timeoutSeconds(forMinutes: 0))
        XCTAssertEqual(CommandBuilder.timeoutSeconds(forMinutes: 240), 14400)
    }

    func testURLCommandAndCLIParser() {
        let startURL = URL(string: "sleepskip://start?mode=display&minutes=90&lock=0&lid=0")!
        XCTAssertEqual(
            URLCommandParser.parse(startURL),
            .start(mode: .keepDisplay, minutes: 90, lockOnStart: false, allowClosedLid: false)
        )
        XCTAssertEqual(URLCommandParser.parse(URL(string: "sleepskip://stop")!), .stop)
        XCTAssertEqual(URLCommandParser.parse(URL(string: "sleepskip://lock")!), .lock)
        XCTAssertNil(URLCommandParser.parse(URL(string: "https://example.com")!))

        XCTAssertEqual(
            CLIParser.parse(arguments: ["SleepSkip", "--display", "--lock", "--", "codex", "run"]),
            .runCommand(arguments: ["codex", "run"], mode: .keepDisplay, lockOnFinish: true)
        )
        XCTAssertEqual(
            CLIParser.parse(arguments: ["SleepSkip", "watch", "4321", "--lock"]),
            .watchPID(pid: 4321, mode: .background, lockOnFinish: true)
        )
        XCTAssertEqual(CLIParser.parse(arguments: ["SleepSkip", "--open"]), .gui(openPopover: true))
    }

    func testCLIParserDoesNotHijackPassthroughArguments() {
        // Regression: `--version` / `--help` after `--` belong to the wrapped command.
        XCTAssertEqual(
            CLIParser.parse(arguments: ["SleepSkip", "--", "codex", "--version"]),
            .runCommand(arguments: ["codex", "--version"], mode: .background, lockOnFinish: false)
        )
        XCTAssertEqual(
            CLIParser.parse(arguments: ["SleepSkip", "--", "npm", "-v"]),
            .runCommand(arguments: ["npm", "-v"], mode: .background, lockOnFinish: false)
        )
        XCTAssertEqual(
            CLIParser.parse(arguments: ["SleepSkip", "--", "claude", "--help"]),
            .runCommand(arguments: ["claude", "--help"], mode: .background, lockOnFinish: false)
        )
        // Options before `--` still work, and `--version` alone still reports the version.
        XCTAssertEqual(CLIParser.parse(arguments: ["SleepSkip", "--version"]), .version)
        XCTAssertEqual(CLIParser.parse(arguments: ["SleepSkip", "--help"]), .help)
        XCTAssertEqual(CLIParser.parse(arguments: ["SleepSkip", "--"]), .help)
    }

    func testNonFiniteDurationsAreRejected() {
        // Regression: Double("inf") used to trap in Int(_:) and poison persisted config.
        for raw in ["inf", "Infinity", "-inf", "1e999", "nan"] {
            guard let value = Double(raw) else { continue }
            XCTAssertNil(
                CommandBuilder.timeoutSeconds(forMinutes: value),
                "\(raw) must not produce a timeout"
            )
        }
        // Finite overflow is clamped to the maximum instead of trapping.
        XCTAssertEqual(
            CommandBuilder.timeoutSeconds(forMinutes: 1e300),
            CommandBuilder.timeoutSeconds(forMinutes: CommandBuilder.maxDurationMinutes)
        )
        XCTAssertNil(CommandBuilder.sanitizeMinutes(.infinity))
        XCTAssertNil(CommandBuilder.sanitizeMinutes(.nan))
        XCTAssertNil(CommandBuilder.sanitizeMinutes(-5))
        XCTAssertEqual(
            CommandBuilder.sanitizeMinutes(CommandBuilder.maxDurationMinutes * 10),
            CommandBuilder.maxDurationMinutes
        )
        XCTAssertEqual(DurationFormatter.formatDuration(.infinity, isChinese: false), "Indefinite")
        XCTAssertEqual(DurationFormatter.formatDuration(.nan, isChinese: true), "永久")
        XCTAssertEqual(DurationFormatter.formatShortPreset(.infinity, isChinese: false), "∞")

        // A poisoned stored value must not survive loading.
        let suiteName = "io.github.laiyongqiang.SleepSkip.poison.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Double.infinity, forKey: "sleepskip.durationMinutes")
        defaults.set(Double.nan, forKey: "sleepskip.customMinutes")
        let loaded = PreferencesStore(defaults: defaults).load()
        XCTAssertEqual(loaded.durationMinutes, 240)
        XCTAssertEqual(loaded.customMinutes, 90)
    }

    func testURLMinutesSanitized() {
        let inf = URLCommandParser.parse(URL(string: "sleepskip://start?minutes=inf")!)
        XCTAssertEqual(inf, .start(mode: nil, minutes: nil, lockOnStart: nil, allowClosedLid: nil))
        let huge = URLCommandParser.parse(URL(string: "sleepskip://start?minutes=1e300")!)
        XCTAssertEqual(
            huge,
            .start(mode: nil, minutes: CommandBuilder.maxDurationMinutes, lockOnStart: nil, allowClosedLid: nil)
        )
    }

    func testMigratesSettingsFromPreRenameDomain() throws {
        let newSuite = "io.github.laiyongqiang.SleepSkip.migrate.\(UUID().uuidString)"
        let oldSuite = "io.github.laiyongqiang.SleepGuard.migrate.\(UUID().uuidString)"
        let newDefaults = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        let oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        defer {
            newDefaults.removePersistentDomain(forName: newSuite)
            oldDefaults.removePersistentDomain(forName: oldSuite)
        }

        oldDefaults.set("keepDisplay", forKey: "sleepguard.mode")
        oldDefaults.set(90.0, forKey: "sleepguard.durationMinutes")
        oldDefaults.set("en", forKey: "sleepguard.language")

        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        let migrated = PreferencesStore(defaults: newDefaults).load()
        XCTAssertEqual(migrated.mode, .keepDisplay)
        XCTAssertEqual(migrated.durationMinutes, 90)
        XCTAssertEqual(migrated.language, .en)

        // One-shot: later changes in the old domain must not leak into the new one.
        oldDefaults.set("background", forKey: "sleepguard.mode")
        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        XCTAssertEqual(PreferencesStore(defaults: newDefaults).load().mode, .keepDisplay)
    }

    func testMigrationDoesNotOverwriteExistingSettings() throws {
        let newSuite = "io.github.laiyongqiang.SleepSkip.existing.\(UUID().uuidString)"
        let oldSuite = "io.github.laiyongqiang.SleepGuard.existing.\(UUID().uuidString)"
        let newDefaults = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        let oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        defer {
            newDefaults.removePersistentDomain(forName: newSuite)
            oldDefaults.removePersistentDomain(forName: oldSuite)
        }

        newDefaults.set("background", forKey: "sleepskip.mode")
        oldDefaults.set("keepDisplay", forKey: "sleepguard.mode")

        PreferencesStore.migrateFromLegacyDomainIfNeeded(defaults: newDefaults, legacyDefaults: oldDefaults)
        XCTAssertEqual(PreferencesStore(defaults: newDefaults).load().mode, .background)
    }

    func testPreferencesPersistenceRoundTrip() throws {
        let suiteName = "io.github.laiyongqiang.SleepSkip.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        let initial = store.load()
        XCTAssertEqual(initial.mode, .background)
        XCTAssertEqual(initial.durationMinutes, 240)
        XCTAssertEqual(initial.lockOnStart, true)
        XCTAssertEqual(initial.allowClosedLid, false)
        XCTAssertEqual(initial.stopOnUnplug, false)
        XCTAssertEqual(initial.autoFollowAgents, true)
        XCTAssertEqual(initial.batteryThresholdPercent, 10)

        var updated = initial
        updated.mode = .keepDisplay
        updated.durationMinutes = 90
        updated.customMinutes = 90
        updated.lockOnStart = false
        updated.allowClosedLid = true
        updated.stopOnUnplug = true
        updated.autoFollowAgents = false
        updated.language = .en
        store.save(updated)

        XCTAssertEqual(store.load(), updated)
    }

    func testSessionManagerLifecycleAndPreFlightGuards() throws {
        let suiteName = "io.github.laiyongqiang.SleepSkip.sm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
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
            nowProvider: { currentTime },
            checkStaleSleepOnInit: false
        )

        var closeCount = 0
        manager.onRequestClosePopover = { closeCount += 1 }

        // Pre-flight low battery blocks before calling BackpackGuard
        manager.setAllowClosedLid(true)
        pwr.snapshot = PowerSnapshot(onBattery: true, percentage: 8)
        manager.startConfiguredSession()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(bag.enableCalls, 0)
        XCTAssertNotNil(manager.errorMessage)

        // Start in KeepDisplay (no lock): stays open in popover!
        pwr.snapshot = PowerSnapshot(onBattery: false, percentage: 90)
        manager.selectMode(.keepDisplay)
        manager.startConfiguredSession()
        XCTAssertTrue(manager.isRunning)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(lock.lockCount, 0)
        XCTAssertTrue(notif.sent.isEmpty)

        // Advance 100s, extend 30m, switch mode cleanly
        currentTime = currentTime.addingTimeInterval(100)
        manager.refreshDisplayTick()
        XCTAssertEqual(manager.remainingSeconds, 14300)

        manager.extendSession(byMinutes: 30)
        XCTAssertEqual(manager.remainingSeconds, 16100)

        caf.shouldThrowOnStart = true
        manager.switchRunningMode(to: .background)
        XCTAssertEqual(manager.activeMode, .keepDisplay)
        XCTAssertNotNil(manager.errorMessage)

        caf.shouldThrowOnStart = false
        manager.switchRunningMode(to: .background)
        XCTAssertEqual(manager.activeMode, .background)

        // Wake reconciliation catches dead child
        caf.isActive = false
        manager.reconcileOnWakeOrShow()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(notif.sent.count, 1)
    }

    func testLiveCaffeinateProcessExitsWhenSentinelExits() throws {
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
        XCTAssertTrue(caffeinate.isRunning)

        sentinel.terminate()
        sentinel.waitUntilExit()
        caffeinate.waitUntilExit()

        XCTAssertFalse(caffeinate.isRunning)
        XCTAssertEqual(caffeinate.terminationStatus, 0)
    }

    // MARK: - Lid guard launch command (regression: silent no-op)

    /// The guard lives under `~/Library/Application Support/SleepSkip/`, which contains a space.
    /// Before this was quoted, `do shell script` split the path, the script never ran, and the
    /// command still exited 0 — the UI reported success while lid sleep was never disabled.
    func testClosedLidLaunchScriptQuotesPathsWithSpaces() {
        let script = "/Users/me/Library/Application Support/SleepSkip/lid-guard.sh"
        let pid = script + ".pid"
        let command = CommandBuilder.closedLidLaunchScript(scriptPath: script, pidPath: pid)

        XCTAssertTrue(command.contains("'/Users/me/Library/Application Support/SleepSkip/lid-guard.sh'"))
        XCTAssertTrue(command.contains("'/Users/me/Library/Application Support/SleepSkip/lid-guard.sh.pid'"))
        // An unquoted path would leave a bare `Application` token in the command.
        XCTAssertFalse(command.contains("/bin/sh /Users/me/Library/Application "))
    }

    func testShellSingleQuotingEscapesEmbeddedApostrophes() {
        XCTAssertEqual(CommandBuilder.shellSingleQuoted("/tmp/plain"), "'/tmp/plain'")
        XCTAssertEqual(CommandBuilder.shellSingleQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
        XCTAssertEqual(CommandBuilder.shellSingleQuoted(""), "''")
    }

    /// End-to-end check that the quoted form actually runs the script. Uses /bin/sh directly, so
    /// it exercises the same parsing `do shell script` performs without needing authorization.
    func testClosedLidLaunchScriptActuallyRunsTheGuard() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepSkip Test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = dir.appendingPathComponent("ran.txt")
        let scriptURL = dir.appendingPathComponent("lid-guard.sh")
        try "#!/bin/sh\necho ok > \(CommandBuilder.shellSingleQuoted(marker.path))\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let command = CommandBuilder.closedLidLaunchScript(
            scriptPath: scriptURL.path,
            pidPath: scriptURL.path + ".pid"
        )
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", command]
        try shell.run()
        shell.waitUntilExit()

        // The guard is backgrounded, so give it a moment to write the marker.
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "quoted launch command did not execute the guard script"
        )
    }

    // MARK: - Auto-follow release (regression: assertion held after agents go quiet)

    private func makeManager(
        caf: MockCaffeinateRunner,
        bag: MockBackpackGuard = MockBackpackGuard(),
        notif: MockNotifier = MockNotifier(),
        now: @escaping () -> Date = { Date() }
    ) throws -> (SessionManager, UserDefaults, String) {
        let suiteName = "io.github.laiyongqiang.SleepSkip.af.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let manager = SessionManager(
            store: PreferencesStore(defaults: defaults),
            caffeinateRunner: caf,
            backpackGuard: bag,
            powerMonitor: MockPowerMonitor(),
            screenLocker: MockScreenLocker(),
            notifier: notif,
            loginItem: MockLoginItem(),
            nowProvider: now,
            checkStaleSleepOnInit: false
        )
        return (manager, defaults, suiteName)
    }

    /// `beginAutoFollow` sets `isRunning`, so guarding on `isRunning` alone made the first
    /// `.active` swallow every later transition, including `.inactive`.
    func testAutoFollowReleasesWhenAgentsGoQuiet() throws {
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.handleAgentActivity(.active(agents: ["Claude Code"], since: Date()))
        XCTAssertTrue(manager.isRunning, "auto-follow should start a session")
        XCTAssertTrue(manager.isFollowingAgents)

        manager.handleAgentActivity(.inactive)
        XCTAssertFalse(manager.isRunning, "auto-follow must release once the agents go quiet")
        XCTAssertFalse(manager.isFollowingAgents)
        XCTAssertEqual(caf.stopCount, 1)
    }

    func testAutoFollowDoesNotOverrideAManualSession() throws {
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.startConfiguredSession()
        XCTAssertTrue(manager.isRunning)
        let startsAfterManual = caf.startCount

        manager.handleAgentActivity(.active(agents: ["Claude Code"], since: Date()))
        XCTAssertEqual(caf.startCount, startsAfterManual, "a manual session must not be re-launched by auto-follow")
        XCTAssertFalse(manager.isFollowingAgents)

        manager.handleAgentActivity(.inactive)
        XCTAssertTrue(manager.isRunning, "a manual session must survive agents going quiet")
    }

    /// The hard ceiling must actually stop holding, not re-arm a second later.
    func testAutoFollowLimitSuppressesUntilAgentsGoQuiet() throws {
        let caf = MockCaffeinateRunner()
        let (manager, defaults, suite) = try makeManager(caf: caf)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAutoFollowEnabled(true)
        manager.handleAgentActivity(.active(agents: ["Claude Code"], since: Date()))
        XCTAssertTrue(manager.isRunning)

        manager.handleAutoFollowLimitReached()
        XCTAssertFalse(manager.isRunning, "the ceiling must release the assertion")
        XCTAssertTrue(manager.autoFollowLimitReached)

        // The monitor keeps reporting `.active` for a still-writing agent; that must not re-arm.
        manager.handleAgentActivity(.active(agents: ["Claude Code"], since: Date()))
        XCTAssertFalse(manager.isRunning, "the ceiling must hold until the agents go quiet")

        // Once quiet, the suppression clears and a fresh detection can follow again.
        manager.handleAgentActivity(.inactive)
        manager.handleAgentActivity(.active(agents: ["Claude Code"], since: Date()))
        XCTAssertTrue(manager.isRunning)
    }

    // MARK: - Authorization race

    /// Stopping while Touch ID is pending used to launch the session anyway when the prompt
    /// returned, because the completion only compared its token.
    func testStoppingDuringAuthorizationCancelsTheLaunch() throws {
        let caf = MockCaffeinateRunner()
        let bag = MockBackpackGuard()
        let (manager, defaults, suite) = try makeManager(caf: caf, bag: bag)
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.setAllowClosedLid(true)
        manager.startConfiguredSession()
        XCTAssertTrue(manager.isAuthorizing)
        XCTAssertEqual(bag.enableCalls, 1)

        manager.stopSession(reason: .manual)
        XCTAssertFalse(manager.isAuthorizing)

        // The mock completes synchronously inside `enable`, so a session that launched would
        // already be running; assert the stop was not undone.
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(caf.startCount, 0)
    }
}
#endif
