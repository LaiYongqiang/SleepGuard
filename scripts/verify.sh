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
        let url = URL(string: "sleepguard://start?mode=display&minutes=90&lock=0")!
        expect(URLCommandParser.parse(url) == .start(mode: .keepDisplay, minutes: 90, lockOnStart: false, allowClosedLid: nil), "URL start parsing")
        expect(URLCommandParser.parse(URL(string: "sleepguard://stop")!) == .stop, "URL stop parsing")
        expect(CLIParser.parse(arguments: ["SleepGuard", "--display", "--lock", "--", "codex", "fix"]) == .runCommand(arguments: ["codex", "fix"], mode: .keepDisplay, lockOnFinish: true), "CLI command parsing")
        expect(CLIParser.parse(arguments: ["SleepGuard", "watch", "999"]) == .watchPID(pid: 999, mode: .background, lockOnFinish: false), "CLI watch PID parsing")

        // 3. PreferencesStore round-trip
        let suiteName = "io.github.laiyongqiang.SleepGuard.verify.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        var cfg = store.load()
        expect(cfg.mode == .background && cfg.durationMinutes == 240 && cfg.lockOnStart && !cfg.stopOnUnplug, "Defaults match spec")
        cfg.stopOnUnplug = true
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

        print("ALL VERIFICATION CHECKS PASSED (5/5)")
    }
}
SWIFT

swiftc -O Sources/SleepGuardCore/*.swift "$DRIVER" -o "$BIN"
"$BIN"
rm -rf .build/verify
