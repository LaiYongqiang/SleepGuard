import Darwin
import Foundation

/// Samples a process's cumulative CPU time and wakeup count over a fixed window.
///
/// Uses `proc_pid_rusage`, which reports the process's own usage — unlike `ps`, whose RSS
/// column also counts shared library pages and overstates a small app's memory several-fold.
///
///     swift scripts/bench_idle.swift <pid> [seconds]
///
/// Prints one line of machine-readable output so runs can be pasted side by side.

func sample(_ pid: pid_t) -> (cpuMillis: Double, wakeups: UInt64, idleWakeups: UInt64)? {
    var info = rusage_info_current()
    let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
        }
    }
    guard status == 0 else { return nil }

    let total = info.ri_user_time + info.ri_system_time
    // ri_*_time is in nanoseconds on macOS; fall back to treating it as microseconds if the
    // value is implausibly small, which is what an older libproc reports.
    let millis = total > 0 ? Double(total) / 1_000_000.0 : 0
    return (millis, info.ri_interrupt_wkups, info.ri_pkg_idle_wkups)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: bench_idle <pid> [seconds]\n".utf8))
    exit(2)
}
let seconds = arguments.count >= 3 ? (Double(arguments[2]) ?? 120) : 120

guard let before = sample(pid) else {
    FileHandle.standardError.write(Data("cannot read rusage for pid \(pid)\n".utf8))
    exit(3)
}

Thread.sleep(forTimeInterval: seconds)

guard let after = sample(pid) else {
    FileHandle.standardError.write(Data("process \(pid) exited during the measurement\n".utf8))
    exit(3)
}

let cpuDelta = after.cpuMillis - before.cpuMillis
let wakeupDelta = after.wakeups &- before.wakeups
let idleWakeupDelta = after.idleWakeups &- before.idleWakeups

print(String(
    format: "window=%.0fs cpu=%.3fms wakeups=%llu pkg_idle_wakeups=%llu",
    seconds, cpuDelta, wakeupDelta, idleWakeupDelta
))
