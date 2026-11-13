import Cocoa
import Darwin
import Foundation
import IOKit.ps
import ServiceManagement
import SleepSkipCore
import UserNotifications

final class CaffeinateRunner: CaffeinateRunning {
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

final class BackpackGuard: BackpackGuarding {
    private var sentinelProcess: Process?
    private var sentinelPipe: Pipe?

    /// Path of the detached guard script, so a leftover run can be terminated on next launch.
    static var scriptPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SleepSkip", isDirectory: true)
        let base = dir ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("lid-guard.sh").path
    }

    static var pidPath: String { scriptPath + ".pid" }

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

        // Write the script to disk and launch it detached. Running it through
        // `do shell script` would block on the output pipe held by the backgrounded child,
        // leaving the UI spinning while the authorization had in fact succeeded.
        let scriptURL = URL(fileURLWithPath: Self.scriptPath)
        do {
            try CommandBuilder.closedLidWatchScript(watchPID: watchPID).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            disable()
            completion(.failure(error))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            let command = CommandBuilder.closedLidLaunchScript(
                scriptPath: scriptURL.path,
                pidPath: Self.pidPath
            )
            let source = "do shell script \"\(command)\" with administrator privileges"
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errorDict)

            guard result != nil else {
                DispatchQueue.main.async {
                    self.disable()
                    let code = (errorDict?[NSAppleScript.errorNumber] as? Int) ?? -1
                    let msg = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "Authorization failed"
                    completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: code, userInfo: [
                        NSLocalizedDescriptionKey: msg
                    ])))
                }
                return
            }

            // `do shell script` exits 0 as long as the shell itself succeeded, which says nothing
            // about whether `pmset` actually took effect (MDM policy, a pmset change, or a script
            // that never launched all still exit 0). Read the real state back before reporting
            // success, so the UI cannot claim "Backpack running" while lid sleep is still enabled.
            self.verifySleepDisabled(retriesRemaining: 10) { verified in
                DispatchQueue.main.async {
                    if verified {
                        completion(.success(()))
                    } else {
                        self.disable()
                        completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "Lid-close sleep was not disabled. The guard may have been blocked by a system policy."
                        ])))
                    }
                }
            }
        }
    }

    /// Polls `SleepDisabled` until it reads 1 or the retries run out.
    ///
    /// The guard script disables sleep asynchronously, so an immediate read can race it. Ten
    /// attempts 200 ms apart give it 2 s, which is far longer than the script needs.
    private func verifySleepDisabled(retriesRemaining: Int, completion: @escaping (Bool) -> Void) {
        checkSleepDisabledAsync { disabled in
            if disabled {
                completion(true)
            } else if retriesRemaining > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                    self.verifySleepDisabled(retriesRemaining: retriesRemaining - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    func disable() {
        try? sentinelPipe?.fileHandleForWriting.close()
        sentinelPipe = nil
        sentinelProcess?.terminate()
        sentinelProcess = nil
        Self.terminateDetachedGuard()
    }

    /// Stops a guard script left running by a previous session. Without this, a crash or force-quit
    /// leaves `disablesleep 1` in place with nothing watching the sentinel.
    static func terminateDetachedGuard() {
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            try? FileManager.default.removeItem(atPath: pidPath)
            return
        }
        // The pid file survives restarts, so verify it still belongs to our script before
        // signalling. `proc_pidpath` reports the *executable*, which for `sh script.sh` is
        // `/bin/bash` or `/bin/sh` — never the script — so match on the command line instead.
        if isOurGuardScript(pid: pid) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// True when `pid` is a live process whose arguments name our guard script.
    ///
    /// `proc_pidpath` reports the *executable*, which for `sh script.sh` is `/bin/bash` — never
    /// the script — so the old `hasSuffix("lid-guard.sh")` check was always false and the safety
    /// net never fired. The script path only appears in argv; see `ProcessArguments`.
    static func isOurGuardScript(pid: Int32) -> Bool {
        guard pid > 0 else { return false }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            // Fast path: the kernel ran the script directly via its shebang.
            if String(cString: pathBuffer).hasSuffix("lid-guard.sh") { return true }
        }

        return ProcessArguments.mentions(pid: pid, scriptName: "lid-guard.sh")
    }

    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) {
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

    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
            let result = script?.executeAndReturnError(&errorDict)

            guard result != nil else {
                DispatchQueue.main.async {
                    let msg = (errorDict?[NSAppleScript.errorMessage] as? String) ?? "Failed to restore normal sleep"
                    completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: msg
                    ])))
                }
                return
            }

            // Same reasoning as `enable`: an exit code of 0 only means the shell ran. Leaving
            // `disablesleep 1` behind is the worse failure of the two, so confirm it actually
            // cleared rather than reporting success on the shell's word alone.
            self.verifySleepEnabled(retriesRemaining: 10) { restored in
                DispatchQueue.main.async {
                    if restored {
                        completion(.success(()))
                    } else {
                        completion(.failure(NSError(domain: "SleepSkip.BackpackGuard", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "Normal sleep could not be restored. Run `sudo pmset -a disablesleep 0` manually."
                        ])))
                    }
                }
            }
        }
    }

    /// Polls `SleepDisabled` until it reads 0 or the retries run out.
    private func verifySleepEnabled(retriesRemaining: Int, completion: @escaping (Bool) -> Void) {
        checkSleepDisabledAsync { disabled in
            if !disabled {
                completion(true)
            } else if retriesRemaining > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                    self.verifySleepEnabled(retriesRemaining: retriesRemaining - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }
}

final class PowerMonitor: PowerMonitoring {
    private var runLoopSource: CFRunLoopSource?
    private var thresholdPercent: Int = 0
    private var stopOnUnplug: Bool = false
    private var wasOnBattery: Bool? = nil
    private var callback: ((PowerEvent) -> Void)?

    func currentPowerSnapshot() -> PowerSnapshot? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for ps in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let powerState = info[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }
            let onBattery = (powerState == kIOPSBatteryPowerValue)
            let capacity = info[kIOPSCurrentCapacityKey as String] as? Int
            return PowerSnapshot(onBattery: onBattery, percentage: capacity)
        }
        return nil
    }

    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) {
        stop()
        guard thresholdPercent > 0 || stopOnUnplug else { return }

        self.thresholdPercent = thresholdPercent
        self.stopOnUnplug = stopOnUnplug
        self.wasOnBattery = currentPowerSnapshot()?.onBattery
        self.callback = onEvent

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
        wasOnBattery = nil
    }

    private func evaluatePowerState() {
        guard thresholdPercent > 0 || stopOnUnplug, let callback else { return }
        guard let snapshot = currentPowerSnapshot() else { return }

        if stopOnUnplug, let prev = wasOnBattery, prev == false, snapshot.onBattery {
            self.stop()
            DispatchQueue.main.async {
                callback(.unplugged)
            }
            return
        }
        wasOnBattery = snapshot.onBattery

        if thresholdPercent > 0, snapshot.onBattery,
           let pct = snapshot.percentage, pct <= thresholdPercent {
            self.stop()
            DispatchQueue.main.async {
                callback(.lowBattery(pct))
            }
        }
    }

    deinit {
        stop()
    }
}

final class ScreenLocker: ScreenLocking {
    static func lockScreenImmediate() {
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

    func lockScreen() {
        Self.lockScreenImmediate()
    }
}

final class NativeNotifier: UserNotifying {
    private var didRequestPermission = false

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func preparePermissionIfNeeded() {
        guard isAppBundle, !didRequestPermission else { return }
        didRequestPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        guard isAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "io.github.laiyongqiang.SleepSkip.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

final class LoginItemManager: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
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
