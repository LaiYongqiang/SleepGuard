import Cocoa
import Darwin
import Foundation
import IOKit.ps
import ServiceManagement
import SleepGuardCore

final class CaffeinateRunner {
    private var process: Process?

    var isActive: Bool {
        process?.isRunning ?? false
    }

    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws {
        let newProc = Process()
        newProc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        newProc.arguments = CommandBuilder.caffeinateArguments(
            mode: mode,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            timeoutSeconds: timeoutSeconds
        )
        newProc.standardInput = FileHandle.nullDevice
        newProc.standardOutput = FileHandle.nullDevice
        newProc.standardError = FileHandle.nullDevice

        newProc.terminationHandler = { [weak self, weak newProc] _ in
            DispatchQueue.main.async {
                guard let self, let newProc, self.process === newProc else { return }
                self.process = nil
                onUnexpectedExit()
            }
        }

        try newProc.run()
        let old = process
        process = newProc
        old?.terminate()
    }

    func stop() {
        let old = process
        process = nil
        old?.terminate()
    }
}

final class BackpackGuard {
    private var sentinelProcess: Process?
    private var sentinelPipe: Pipe?

    var isActive: Bool {
        sentinelProcess?.isRunning ?? false
    }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        disable()

        let pipe = Pipe()
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/cat")
        cat.standardInput = pipe
        cat.standardOutput = FileHandle.nullDevice
        cat.standardError = FileHandle.nullDevice

        do {
            try cat.run()
        } catch {
            completion(.failure(error))
            return
        }

        sentinelPipe = pipe
        sentinelProcess = cat
        let watchPID = cat.processIdentifier
        let shellCommand = CommandBuilder.closedLidWatchScript(watchPID: watchPID)

        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"\(shellCommand)\" with administrator privileges")
            let result = script?.executeAndReturnError(&errorDict)

            DispatchQueue.main.async {
                if result != nil {
                    completion(.success(()))
                } else {
                    self.disable()
                    let code = (errorDict?[NSAppleScript.errorNumber] as? Int) ?? -1
                    let msg = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "Authorization failed"
                    completion(.failure(NSError(domain: "SleepGuard.BackpackGuard", code: code, userInfo: [
                        NSLocalizedDescriptionKey: msg
                    ])))
                }
            }
        }
    }

    func disable() {
        try? sentinelPipe?.fileHandleForWriting.close()
        sentinelPipe = nil
        sentinelProcess?.terminate()
        sentinelProcess = nil
    }

    static func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            var disabled = false
            if (try? task.run()) != nil {
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                disabled = PowerOutputParser.parseSleepDisabled(fromPmsetOutput: output)
            }
            DispatchQueue.main.async {
                completion(disabled)
            }
        }
    }

    static func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
            let result = script?.executeAndReturnError(&errorDict)
            DispatchQueue.main.async {
                if result != nil {
                    completion(.success(()))
                } else {
                    let msg = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "Failed to restore normal sleep"
                    completion(.failure(NSError(domain: "SleepGuard.BackpackGuard", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: msg
                    ])))
                }
            }
        }
    }
}

final class PowerMonitor {
    private var runLoopSource: CFRunLoopSource?
    private var thresholdPercent: Int = 0
    private var callback: ((Int) -> Void)?

    func start(thresholdPercent: Int, onLowBattery: @escaping (Int) -> Void) {
        stop()
        guard thresholdPercent > 0 else { return }

        self.thresholdPercent = thresholdPercent
        self.callback = onLowBattery

        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.evaluatePowerState()
        }, unmanagedSelf)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        evaluatePowerState()
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        callback = nil
    }

    private func evaluatePowerState() {
        guard thresholdPercent > 0, let callback else { return }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }

        for ps in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let powerState = info[kIOPSPowerSourceStateKey as String] as? String,
                  powerState == kIOPSBatteryPowerValue,
                  let currentCapacity = info[kIOPSCurrentCapacityKey as String] as? Int else {
                continue
            }
            if currentCapacity <= thresholdPercent {
                self.stop()
                DispatchQueue.main.async {
                    callback(currentCapacity)
                }
                return
            }
        }
    }

    deinit {
        stop()
    }
}

enum ScreenLocker {
    static func lockScreen() {
        typealias LockFn = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            let lockFn = unsafeBitCast(sym, to: LockFn.self)
            lockFn()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}

enum Notifier {
    static func send(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}

enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
