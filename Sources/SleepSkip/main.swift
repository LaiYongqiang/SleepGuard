import Cocoa
import Foundation
import SleepSkipCore

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

/// Tracks the wrapped command so SIGINT/SIGTERM can be forwarded to it.
/// The command is spawned directly by this process (not by caffeinate): caffeinate does not
/// forward signals, so wrapping it would leave Ctrl+C unable to stop the wrapped agent.
///
/// The pid lives in a C `sig_atomic_t` rather than behind an `NSLock`. A signal handler may
/// interrupt the main thread at any instruction, including while that same thread holds the
/// lock, and `NSLock` is not async-signal-safe — re-entering it there deadlocks the process.
/// A single word of naturally-aligned integer storage needs no lock for the handler's read,
/// and `kill(2)` is itself async-signal-safe.
private final class CLIChildProcess: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)

    init() {
        storage.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func set(_ pid: pid_t) {
        storage.pointee = sig_atomic_t(pid)
    }

    /// Zero means "no child to forward to"; the child's exit is recorded by clearing the pid.
    func clear() {
        storage.pointee = 0
    }

    /// Async-signal-safe: reads one word and calls kill(2).
    func forward(_ signalNumber: Int32) {
        let target = pid_t(storage.pointee)
        guard target > 0 else { return }
        kill(target, signalNumber)
    }
}

private let cliChild = CLIChildProcess()

private func installSignalForwarding() {
    signal(SIGINT) { _ in cliChild.forward(SIGINT) }
    signal(SIGTERM) { _ in cliChild.forward(SIGTERM) }
    // A dropped terminal should not kill a long agent run; SIGHUP is handled by the shell.
    signal(SIGPIPE, SIG_IGN)
}

/// Runs `command` as a child while a separate `caffeinate -w <childPID>` holds the assertion.
/// Returns the child's exit status, mapping signal deaths to the conventional 128 + signal code.
private func runWatched(arguments: [String], mode: GuardMode, commandLabel: String, lockOnFinish: Bool) -> Int32 {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    postCLIDistributedNotification(IPCNotifications.cliStarted, pid: selfPID, commandName: commandLabel, mode: mode)
    defer {
        postCLIDistributedNotification(IPCNotifications.cliStopped, pid: selfPID, commandName: commandLabel, mode: mode)
        if lockOnFinish {
            ScreenLocker.lockScreenImmediate()
        }
    }

    installSignalForwarding()

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = arguments
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError

    do {
        try child.run()
    } catch {
        fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
        return 1
    }
    cliChild.set(child.processIdentifier)

    let assertion = Process()
    assertion.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    assertion.arguments = mode.caffeinateAssertionFlags + ["-w", "\(child.processIdentifier)"]
    assertion.standardInput = FileHandle.nullDevice
    assertion.standardOutput = FileHandle.nullDevice
    assertion.standardError = FileHandle.nullDevice
    // A missing assertion is survivable: the command still runs, only sleep prevention is lost.
    try? assertion.run()

    child.waitUntilExit()
    cliChild.clear()
    if assertion.isRunning {
        assertion.terminate()
        assertion.waitUntilExit()
    }

    switch child.terminationReason {
    case .uncaughtSignal:
        return 128 + child.terminationStatus
    default:
        return child.terminationStatus
    }
}

private func runWatchPID(targetPID: Int32, mode: GuardMode, lockOnFinish: Bool) -> Int32 {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    let label = "PID \(targetPID)"
    postCLIDistributedNotification(IPCNotifications.cliStarted, pid: selfPID, commandName: label, mode: mode)
    defer {
        postCLIDistributedNotification(IPCNotifications.cliStopped, pid: selfPID, commandName: label, mode: mode)
        if lockOnFinish {
            ScreenLocker.lockScreenImmediate()
        }
    }

    let assertion = Process()
    assertion.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    assertion.arguments = mode.caffeinateAssertionFlags + ["-w", "\(targetPID)"]
    assertion.standardInput = FileHandle.nullDevice
    assertion.standardOutput = FileHandle.nullDevice
    assertion.standardError = FileHandle.nullDevice

    do {
        try assertion.run()
    } catch {
        fputs("SleepSkip CLI error: \(error.localizedDescription)\n", stderr)
        return 1
    }

    // Ctrl+C here should release the assertion rather than leave a watcher behind.
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        if assertion.isRunning {
            assertion.terminate()
        }
    }
    source.resume()
    defer { source.cancel() }

    assertion.waitUntilExit()
    return assertion.terminationStatus
}

switch CLIParser.parse(arguments: CommandLine.arguments) {
case .version:
    print("SleepSkip \(AppInfo.version)")
    exit(0)

case .help:
    print("""
    SleepSkip — Ultra-lightweight macOS keep-awake menu bar & CLI utility
    Usage:
      SleepSkip                         Launch menu bar app
      SleepSkip --open                  Launch and open popover immediately
      SleepSkip [--display] [--lock] -- <command...>
                                         Keep Mac awake until <command> finishes
      SleepSkip watch [--display] [--lock] <pid>
                                         Keep Mac awake until existing <pid> exits
      SleepSkip --version               Show version
    """)
    exit(0)

case .runCommand(let cmdArgs, let mode, let lockOnFinish):
    guard let executable = cmdArgs.first, !executable.isEmpty else {
        fputs("SleepSkip CLI error: no command given after --\n", stderr)
        exit(2)
    }
    let cmdLabel = URL(fileURLWithPath: executable).lastPathComponent
    let status = runWatched(
        arguments: cmdArgs,
        mode: mode,
        commandLabel: cmdLabel,
        lockOnFinish: lockOnFinish
    )
    exit(status)

case .watchPID(let targetPID, let mode, let lockOnFinish):
    exit(runWatchPID(targetPID: targetPID, mode: mode, lockOnFinish: lockOnFinish))

case .invalid(let reason):
    fputs("SleepSkip CLI error: \(reason)\nRun `SleepSkip --help` for usage.\n", stderr)
    exit(2)

case .gui:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
