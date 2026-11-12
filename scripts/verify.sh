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

        let watchScript = CommandBuilder.closedLidWatchScript(watchPID: 9999)
        expect(watchScript.contains("pmset -a disablesleep 1"), "Watch script enables disablesleep")
        expect(watchScript.contains("pmset -a disablesleep 0"), "Watch script restores disablesleep")
        expect(watchScript.contains("caffeinate -i -w 9999"), "Watch script watches PID via caffeinate -w")

        // 2. DurationFormatter checks
        expect(DurationFormatter.formatCountdown(14356) == "03:59:16", "HH:MM:SS formatting")
        expect(DurationFormatter.formatDuration(240, isChinese: true) == "4 小时", "Chinese duration")
        expect(DurationFormatter.formatDuration(240, isChinese: false) == "4 hours", "English duration")
        expect(DurationFormatter.formatDuration(0, isChinese: false) == "Indefinite", "Indefinite duration")

        // 3. PreferencesStore defaults & persistence
        let suiteName = "io.github.laiyongqiang.SleepGuard.verify.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        let initial = store.load()
        expect(initial.mode == .background, "Default mode is background")
        expect(initial.durationMinutes == 240, "Default duration is 4h (240m)")
        expect(initial.lockOnStart == true, "Default lockOnStart is true")
        expect(initial.allowClosedLid == false, "Default allowClosedLid is false")
        expect(initial.batteryThresholdPercent == 10, "Default battery cutoff is 10%")

        var updated = initial
        updated.mode = .keepDisplay
        updated.durationMinutes = 90
        updated.customMinutes = 90
        updated.lockOnStart = false
        updated.allowClosedLid = true
        updated.batteryThresholdPercent = 15
        updated.language = .en
        store.save(updated)
        expect(store.load() == updated, "Preferences round-trip persistence")

        // 4. PowerOutputParser checks
        expect(
            PowerOutputParser.parseSleepDisabled(fromPmsetOutput: " SleepDisabled\t\t1\n") == true,
            "Parse SleepDisabled = 1"
        )
        expect(
            PowerOutputParser.parseSleepDisabled(fromPmsetOutput: " SleepDisabled\t\t0\n") == false,
            "Parse SleepDisabled = 0"
        )

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
