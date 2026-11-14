import Foundation
import IOKit.ps
import SleepSkipCore

/// Keeps lid-close sleep suppressed without any authorization.
///
/// Two layers, because the flag can be reset behind our back:
///
/// - **Event-driven**: re-arms the moment the power source changes. Cheap (~52 µs) and lands
///   within one run-loop turn.
/// - **1 Hz timer**: re-arms every second. Measured at 52.5 µs per call, so a full hour costs
///   about 189 ms of CPU (~0.005%) — two orders of magnitude below Never Sleep's 2.75%, whose
///   cost is SwiftUI redrawing rather than the IOKit call.
///
/// Neither layer closes the one gap that matters: with the lid already shut, **plugging the
/// cable back in** makes powerd sleep the machine 6–9 s later regardless of this flag, because
/// its power-change path re-evaluates the lid without consulting selector 12. Re-arming every
/// second does not help — the decision is already made. That is why `ClosedLidStrategy` also
/// offers the privileged `pmset` path, which does survive a power change.
final class UnprivilegedLidGuard: ClosedLidGuarding {
    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private var isActive = false

    var isEngaged: Bool { isActive }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        disable()

        guard ClamshellFlag.setLidSleepSuppressed(true) else {
            completion(.failure(NSError(
                domain: "SleepSkip.UnprivilegedLidGuard",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "The system rejected the lid-sleep request. Try the privileged mode instead."]
            )))
            return
        }

        isActive = true
        startTimer()
        startPowerSourceObserver()
        completion(.success(()))
    }

    func disable() {
        isActive = false
        timer?.invalidate()
        timer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        ClamshellFlag.setLidSleepSuppressed(false)
    }

    /// The guard must not outlive the process, and a leftover flag would silently keep the Mac
    /// awake after a crash. Clearing it here covers the normal exit path; the flag is also
    /// process-independent, so a relaunch simply re-arms it.
    deinit {
        timer?.invalidate()
        ClamshellFlag.setLidSleepSuppressed(false)
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            ClamshellFlag.setLidSleepSuppressed(true)
        }
        // Common mode so the re-arm keeps running while a menu or popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startPowerSourceObserver() {
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let guardObject = Unmanaged<UnprivilegedLidGuard>.fromOpaque(context).takeUnretainedValue()
            guard guardObject.isActive else { return }
            ClamshellFlag.setLidSleepSuppressed(true)
        }, unmanagedSelf)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }
}
