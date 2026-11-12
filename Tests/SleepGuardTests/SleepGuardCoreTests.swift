#if canImport(XCTest)
import Foundation
import XCTest
@testable import SleepGuardCore

final class SleepGuardCoreTests: XCTestCase {
    func testCommandBuilderTimedAndIndefinite() {
        let bgTimed = CommandBuilder.caffeinateArguments(mode: .background, parentPID: 1234, timeoutSeconds: 14400)
        XCTAssertEqual(bgTimed, ["-i", "-w", "1234", "-t", "14400"])

        let dispIndefinite = CommandBuilder.caffeinateArguments(mode: .keepDisplay, parentPID: 5678, timeoutSeconds: nil)
        XCTAssertEqual(dispIndefinite, ["-di", "-w", "5678"])

        XCTAssertNil(CommandBuilder.timeoutSeconds(forMinutes: 0))
        XCTAssertEqual(CommandBuilder.timeoutSeconds(forMinutes: 30), 1800)
        XCTAssertEqual(CommandBuilder.timeoutSeconds(forMinutes: 240), 14400)
    }

    func testClosedLidWatchScriptContainsTrapAndWait() {
        let script = CommandBuilder.closedLidWatchScript(watchPID: 9999)
        XCTAssertTrue(script.contains("pmset -a disablesleep 1"))
        XCTAssertTrue(script.contains("pmset -a disablesleep 0"))
        XCTAssertTrue(script.contains("caffeinate -i -w 9999"))
        XCTAssertTrue(script.contains("trap"))
    }

    func testDurationFormatter() {
        XCTAssertEqual(DurationFormatter.formatCountdown(14356), "03:59:16")
        XCTAssertEqual(DurationFormatter.formatCountdown(0), "00:00:00")
        XCTAssertEqual(DurationFormatter.formatCountdown(-5), "00:00:00")

        XCTAssertEqual(DurationFormatter.formatDuration(240, isChinese: true), "4 小时")
        XCTAssertEqual(DurationFormatter.formatDuration(30, isChinese: true), "30 分钟")
        XCTAssertEqual(DurationFormatter.formatDuration(0, isChinese: true), "永久")

        XCTAssertEqual(DurationFormatter.formatDuration(240, isChinese: false), "4 hours")
        XCTAssertEqual(DurationFormatter.formatDuration(60, isChinese: false), "1 hour")
        XCTAssertEqual(DurationFormatter.formatDuration(0, isChinese: false), "Indefinite")
    }

    func testPreferencesStoreDefaultsAndPersistence() throws {
        let suiteName = "io.github.laiyongqiang.SleepGuard.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        let initial = store.load()
        XCTAssertEqual(initial.mode, .background)
        XCTAssertEqual(initial.durationMinutes, 240)
        XCTAssertTrue(initial.lockOnStart)
        XCTAssertFalse(initial.allowClosedLid)
        XCTAssertEqual(initial.batteryThresholdPercent, 10)

        var updated = initial
        updated.mode = .keepDisplay
        updated.durationMinutes = 90
        updated.customMinutes = 90
        updated.lockOnStart = false
        updated.allowClosedLid = true
        updated.batteryThresholdPercent = 15
        updated.language = .en
        store.save(updated)

        let reloaded = store.load()
        XCTAssertEqual(reloaded, updated)
    }

    func testPowerOutputParser() {
        let disabledSample = """
        System-wide power settings:
         SleepDisabled\t\t1
         displaysleep\t\t10
        """
        XCTAssertTrue(PowerOutputParser.parseSleepDisabled(fromPmsetOutput: disabledSample))

        let normalSample = """
        System-wide power settings:
         SleepDisabled\t\t0
         sleep\t\t1
        """
        XCTAssertFalse(PowerOutputParser.parseSleepDisabled(fromPmsetOutput: normalSample))
    }

    func testCaffeinateExitsWhenWatchedProcessTerminates() throws {
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
        XCTAssertTrue(caffeinate.isRunning)

        sentinel.terminate()
        sentinel.waitUntilExit()
        caffeinate.waitUntilExit()

        XCTAssertFalse(caffeinate.isRunning)
        XCTAssertEqual(caffeinate.terminationStatus, 0)
    }
}
#endif
