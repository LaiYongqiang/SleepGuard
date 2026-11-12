import Foundation

public enum GuardMode: String, CaseIterable, Identifiable, Sendable {
    /// Prevent idle system sleep while allowing the display to turn off.
    case background = "background"
    /// Prevent both idle system sleep and display sleep.
    case keepDisplay = "keepDisplay"

    public var id: String { rawValue }

    public var caffeinateAssertionFlags: [String] {
        switch self {
        case .background:
            return ["-i"]
        case .keepDisplay:
            return ["-di"]
        }
    }

    public var iconName: String {
        switch self {
        case .background:
            return "laptopcomputer"
        case .keepDisplay:
            return "sun.max"
        }
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public func resolvedIsChinese(preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        switch self {
        case .zhHans:
            return true
        case .en:
            return false
        case .system:
            return preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

public struct SessionConfig: Equatable, Sendable {
    public var mode: GuardMode
    public var durationMinutes: Double
    public var customMinutes: Double
    public var lockOnStart: Bool
    public var allowClosedLid: Bool
    public var batteryThresholdPercent: Int
    public var language: AppLanguage

    public init(
        mode: GuardMode = .background,
        durationMinutes: Double = 240,
        customMinutes: Double = 90,
        lockOnStart: Bool = true,
        allowClosedLid: Bool = false,
        batteryThresholdPercent: Int = 10,
        language: AppLanguage = .system
    ) {
        self.mode = mode
        self.durationMinutes = durationMinutes
        self.customMinutes = customMinutes
        self.lockOnStart = lockOnStart
        self.allowClosedLid = allowClosedLid
        self.batteryThresholdPercent = batteryThresholdPercent
        self.language = language
    }

    public static let standardPresets: [Double] = [30, 60, 120, 240, 0]

    public var effectiveAllowClosedLid: Bool {
        mode == .background && allowClosedLid
    }

    public var effectiveLockOnStart: Bool {
        mode == .background && lockOnStart
    }
}

public enum CommandBuilder {
    public static func caffeinateArguments(
        mode: GuardMode,
        parentPID: Int32,
        timeoutSeconds: Int?
    ) -> [String] {
        var args = mode.caffeinateAssertionFlags
        args.append(contentsOf: ["-w", "\(parentPID)"])
        if let timeoutSeconds, timeoutSeconds > 0 {
            args.append(contentsOf: ["-t", "\(timeoutSeconds)"])
        }
        return args
    }

    public static func timeoutSeconds(forMinutes minutes: Double) -> Int? {
        guard minutes > 0 else { return nil }
        return max(1, Int((minutes * 60.0).rounded()))
    }

    public static func closedLidWatchScript(watchPID: Int32) -> String {
        return """
        /usr/bin/pmset -a disablesleep 1 && (trap '/usr/bin/pmset -a disablesleep 0' EXIT INT TERM; /usr/bin/caffeinate -i -w \(watchPID) >/dev/null 2>&1; /usr/bin/pmset -a disablesleep 0) </dev/null >/dev/null 2>&1 &
        """
    }
}

public enum DurationFormatter {
    public static func formatCountdown(_ totalSeconds: Int) -> String {
        let safe = max(0, totalSeconds)
        let h = safe / 3600
        let m = (safe % 3600) / 60
        let s = safe % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    public static func formatDuration(_ minutes: Double, isChinese: Bool) -> String {
        if minutes <= 0 {
            return isChinese ? "永久" : "Indefinite"
        }
        if minutes < 60 {
            let value = minutes == minutes.rounded() ? "\(Int(minutes))" : String(format: "%.1f", minutes)
            return isChinese ? "\(value) 分钟" : "\(value)m"
        }
        let hours = minutes / 60.0
        let value = hours == hours.rounded() ? "\(Int(hours))" : String(format: "%.1f", hours)
        if isChinese {
            return "\(value) 小时"
        }
        return hours == 1 ? "1 hour" : "\(value) hours"
    }

    public static func formatShortPreset(_ minutes: Double, isChinese: Bool) -> String {
        if minutes <= 0 {
            return isChinese ? "永久" : "∞"
        }
        if minutes < 60 {
            return isChinese ? "\(Int(minutes)) 分" : "\(Int(minutes))m"
        }
        let hours = Int((minutes / 60.0).rounded())
        return isChinese ? "\(hours) 小时" : "\(hours)h"
    }

    public static func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

public enum PowerOutputParser {
    public static func parseSleepDisabled(fromPmsetOutput output: String) -> Bool {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if let last = parts.last, last == "1" {
                    return true
                }
            }
        }
        return false
    }
}
