import Foundation

/// Reads a process's argument vector.
///
/// Lives in Core rather than the app target so it can be exercised by `scripts/verify.sh`,
/// which compiles Core without AppKit. The app uses it to confirm that a pid recorded in the
/// guard's pid file really belongs to our guard script before signalling it.
public enum ProcessArguments {
    /// Returns the argument vector of `pid`, or an empty array when it cannot be read
    /// (no such process, or the caller lacks the entitlement).
    public static func read(pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }

        var raw = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &raw, &size, nil, 0) == 0 else { return [] }

        return parse(raw, count: size)
    }

    /// Decodes a `KERN_PROCARGS2` buffer.
    ///
    /// Layout: `int argc`, the executable path, NUL padding, then `argc` NUL-terminated
    /// arguments. Reading the buffer as a single C string — which an earlier version did —
    /// yields only the executable path, so a script name in argv was never found and the
    /// pid-ownership check silently failed for every interpreter-hosted script.
    ///
    /// Exposed for testing with a synthetic buffer.
    public static func parse(_ raw: [UInt8], count: Int) -> [String] {
        guard count > MemoryLayout<Int32>.size else { return [] }
        let argc = raw.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < count, raw[index] != 0 { index += 1 }
        while index < count, raw[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard index < count else { break }
            let start = index
            while index < count, raw[index] != 0 { index += 1 }
            if let value = String(bytes: raw[start..<index], encoding: .utf8) {
                arguments.append(value)
            }
            index += 1
        }
        return arguments
    }

    /// True when the process's arguments mention `scriptName`.
    public static func mentions(pid: Int32, scriptName: String) -> Bool {
        read(pid: pid).contains { $0.contains(scriptName) }
    }
}
