import Cocoa
import Foundation
import SleepGuardCore

private func postCLIDistributedNotification(_ name: Notification.Name, pid: Int32, commandName: String, mode: GuardMode) {
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        userInfo: [
            "pid": NSNumber(value: pid),
            "cmd": commandName,
            "mode": mode.rawValue,
        ],
        deliverImmediately: true
    )
}

private func runCaffeinateCLI(arguments: [String], mode: GuardMode, commandLabel: String, lockOnFinish: Bool) -> Int32 {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    postCLIDistributedNotification(IPCNotifications.cliStarted, pid: selfPID, commandName: commandLabel, mode: mode)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    proc.arguments = mode.caffeinateAssertionFlags + arguments
    proc.standardInput = FileHandle.standardInput
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError = FileHandle.standardError

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        fputs("SleepGuard CLI error: \(error.localizedDescription)\n", stderr)
        postCLIDistributedNotification(IPCNotifications.cliStopped, pid: selfPID, commandName: commandLabel, mode: mode)
        return 1
    }

    postCLIDistributedNotification(IPCNotifications.cliStopped, pid: selfPID, commandName: commandLabel, mode: mode)
    if lockOnFinish {
        ScreenLocker.lockScreenImmediate()
    }
    return proc.terminationStatus
}

switch CLIParser.parse(arguments: CommandLine.arguments) {
case .version:
    print("SleepGuard 1.1.0")
    exit(0)

case .help:
    print("""
    SleepGuard — Ultra-lightweight macOS keep-awake menu bar & CLI utility
    Usage:
      SleepGuard                         Launch menu bar app
      SleepGuard --open                  Launch and open popover immediately
      SleepGuard [--display] [--lock] -- <command...>
                                         Keep Mac awake until <command> finishes
      SleepGuard watch [--display] [--lock] <pid>
                                         Keep Mac awake until existing <pid> exits
      SleepGuard --version               Show version
    """)
    exit(0)

case .runCommand(let cmdArgs, let mode, let lockOnFinish):
    let cmdLabel = URL(fileURLWithPath: cmdArgs[0]).lastPathComponent
    let status = runCaffeinateCLI(
        arguments: cmdArgs,
        mode: mode,
        commandLabel: cmdLabel,
        lockOnFinish: lockOnFinish
    )
    exit(status)

case .watchPID(let targetPID, let mode, let lockOnFinish):
    let status = runCaffeinateCLI(
        arguments: ["-w", "\(targetPID)"],
        mode: mode,
        commandLabel: "PID \(targetPID)",
        lockOnFinish: lockOnFinish
    )
    exit(status)

case .gui:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
