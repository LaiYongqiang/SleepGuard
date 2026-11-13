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
    public var stopOnUnplug: Bool
    public var autoFollowAgents: Bool
    public var language: AppLanguage

    public init(
        mode: GuardMode = .background,
        durationMinutes: Double = 240,
        customMinutes: Double = 90,
        lockOnStart: Bool = true,
        allowClosedLid: Bool = false,
        batteryThresholdPercent: Int = 10,
        stopOnUnplug: Bool = false,
        autoFollowAgents: Bool = false,
        language: AppLanguage = .system
    ) {
        self.mode = mode
        self.durationMinutes = durationMinutes
        self.customMinutes = customMinutes
        self.lockOnStart = lockOnStart
        self.allowClosedLid = allowClosedLid
        self.batteryThresholdPercent = batteryThresholdPercent
        self.stopOnUnplug = stopOnUnplug
        self.autoFollowAgents = autoFollowAgents
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

public struct PowerSnapshot: Equatable, Sendable {
    public let onBattery: Bool
    public let percentage: Int?

    public init(onBattery: Bool, percentage: Int?) {
        self.onBattery = onBattery
        self.percentage = percentage
    }
}

public enum PowerEvent: Equatable, Sendable {
    case lowBattery(Int)
    case unplugged
}

public struct ExternalCLISession: Equatable, Sendable {
    public let pid: Int32
    public let commandName: String
    public let mode: GuardMode

    public init(pid: Int32, commandName: String, mode: GuardMode) {
        self.pid = pid
        self.commandName = commandName
        self.mode = mode
    }
}

public enum URLCommand: Equatable, Sendable {
    case start(mode: GuardMode?, minutes: Double?, lockOnStart: Bool?, allowClosedLid: Bool?)
    case stop
    case toggle
    case lock
    case open
}

public enum URLCommandParser {
    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "sleepskip" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let action = !host.isEmpty ? host : path

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func boolValue(_ key: String) -> Bool? {
            guard let raw = queryItems.first(where: { $0.name.lowercased() == key })?.value?.lowercased() else {
                return nil
            }
            if ["1", "true", "yes", "on"].contains(raw) { return true }
            if ["0", "false", "no", "off"].contains(raw) { return false }
            return nil
        }

        switch action {
        case "start":
            let modeRaw = queryItems.first(where: { $0.name.lowercased() == "mode" })?.value?.lowercased()
            let mode: GuardMode? = {
                switch modeRaw {
                case "background", "bg": return .background
                case "keepdisplay", "display", "screen": return .keepDisplay
                default: return nil
                }
            }()
            let minutes: Double? = queryItems
                .first(where: { $0.name.lowercased() == "minutes" || $0.name.lowercased() == "duration" })
                .flatMap { $0.value }
                .flatMap { Double($0) }
                .flatMap { CommandBuilder.sanitizeMinutes($0) }
            let lock = boolValue("lock")
            let lid = boolValue("lid")
            return .start(mode: mode, minutes: minutes, lockOnStart: lock, allowClosedLid: lid)
        case "stop":
            return .stop
        case "toggle":
            return .toggle
        case "lock":
            return .lock
        case "open", "":
            return .open
        default:
            return nil
        }
    }
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case gui(openPopover: Bool)
    case watchPID(pid: Int32, mode: GuardMode, lockOnFinish: Bool)
    case runCommand(arguments: [String], mode: GuardMode, lockOnFinish: Bool)
}

public enum CLIParser {
    public static func parse(arguments: [String]) -> CLICommand {
        let args = Array(arguments.dropFirst())

        // Only options before `--` belong to SleepSkip. Everything after it is the wrapped
        // command's own argv and must be passed through untouched, even if it contains
        // `--version` or `--help`.
        let optionArgs: ArraySlice<String>
        let passthroughArgs: [String]
        if let dashIndex = args.firstIndex(of: "--") {
            optionArgs = args[..<dashIndex]
            passthroughArgs = Array(args[(dashIndex + 1)...])
        } else {
            optionArgs = args[...]
            passthroughArgs = []
        }

        if optionArgs.contains("--version") || optionArgs.contains("-v") {
            return .version
        }
        if optionArgs.contains("--help") || optionArgs.contains("-h") {
            return .help
        }

        var mode: GuardMode = .background
        var lockOnFinish = false

        if !passthroughArgs.isEmpty {
            for opt in optionArgs {
                if opt == "--display" || opt == "-d" {
                    mode = .keepDisplay
                } else if opt == "--lock" || opt == "-l" {
                    lockOnFinish = true
                }
            }
            return .runCommand(arguments: passthroughArgs, mode: mode, lockOnFinish: lockOnFinish)
        }

        if args.firstIndex(of: "--") != nil {
            // `--` was given with nothing after it: nothing to run.
            return .help
        }

        if let watchIdx = args.firstIndex(of: "watch") {
            var targetPID: Int32?
            for (idx, token) in args.enumerated() where idx != watchIdx {
                if token == "--display" || token == "-d" {
                    mode = .keepDisplay
                } else if token == "--lock" || token == "-l" {
                    lockOnFinish = true
                } else if targetPID == nil, let pid = Int32(token), pid > 0 {
                    targetPID = pid
                }
            }
            if let targetPID {
                return .watchPID(pid: targetPID, mode: mode, lockOnFinish: lockOnFinish)
            }
            return .help
        }

        return .gui(openPopover: args.contains("--open"))
    }
}

public enum AppInfo {
    /// Single source of truth for the version shown in the CLI banner and the settings panel.
    /// The build script rewrites this value from the git tag, so it never drifts from the release.
    public static let version = "1.2.0"

    public static let repositoryURL = "https://github.com/LaiYongqiang/SleepSkip"
}

public enum CommandBuilder {
    /// Upper bound for a single session. Guards against `Double("inf")`, `1e300`, and typos
    /// that would otherwise crash `Int(_:)` when building the caffeinate timeout.
    public static let maxDurationMinutes: Double = 7 * 24 * 60

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

    /// Normalizes user-supplied minutes: nil when invalid or non-positive (indefinite).
    public static func sanitizeMinutes(_ minutes: Double) -> Double? {
        guard minutes.isFinite, minutes > 0 else { return nil }
        return min(minutes, maxDurationMinutes)
    }

    public static func timeoutSeconds(forMinutes minutes: Double) -> Int? {
        guard let safe = sanitizeMinutes(minutes) else { return nil }
        return max(1, Int((safe * 60.0).rounded()))
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
        // Non-finite or out-of-range values fall back to "Indefinite" rather than trapping in Int(_:).
        guard let minutes = CommandBuilder.sanitizeMinutes(minutes) else {
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
        guard let minutes = CommandBuilder.sanitizeMinutes(minutes) else {
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
