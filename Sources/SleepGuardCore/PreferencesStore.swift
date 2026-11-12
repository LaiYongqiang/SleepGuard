import Foundation

public final class PreferencesStore {
    private enum Keys {
        static let mode = "sleepguard.mode"
        static let durationMinutes = "sleepguard.durationMinutes"
        static let customMinutes = "sleepguard.customMinutes"
        static let lockOnStart = "sleepguard.lockOnStart"
        static let allowClosedLid = "sleepguard.allowClosedLid"
        static let batteryThreshold = "sleepguard.batteryThresholdPercent"
        static let stopOnUnplug = "sleepguard.stopOnUnplug"
        static let language = "sleepguard.language"
        static let hasShownOnboarding = "sleepguard.hasShownOnboarding"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "io.github.laiyongqiang.SleepGuard") ?? .standard) {
        self.defaults = defaults
    }

    public var hasShownOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasShownOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasShownOnboarding) }
    }

    public func load() -> SessionConfig {
        let modeRaw = defaults.string(forKey: Keys.mode) ?? GuardMode.background.rawValue
        let mode = GuardMode(rawValue: modeRaw) ?? .background

        let durationMinutes: Double
        if defaults.object(forKey: Keys.durationMinutes) != nil {
            durationMinutes = defaults.double(forKey: Keys.durationMinutes)
        } else {
            durationMinutes = 240
        }

        let customMinutes: Double
        if defaults.object(forKey: Keys.customMinutes) != nil {
            customMinutes = max(1, defaults.double(forKey: Keys.customMinutes))
        } else {
            customMinutes = 90
        }

        let lockOnStart: Bool
        if defaults.object(forKey: Keys.lockOnStart) != nil {
            lockOnStart = defaults.bool(forKey: Keys.lockOnStart)
        } else {
            lockOnStart = true
        }

        let allowClosedLid: Bool
        if defaults.object(forKey: Keys.allowClosedLid) != nil {
            allowClosedLid = defaults.bool(forKey: Keys.allowClosedLid)
        } else {
            allowClosedLid = false
        }

        let batteryThreshold: Int
        if defaults.object(forKey: Keys.batteryThreshold) != nil {
            batteryThreshold = max(0, defaults.integer(forKey: Keys.batteryThreshold))
        } else {
            batteryThreshold = 10
        }

        let stopOnUnplug: Bool
        if defaults.object(forKey: Keys.stopOnUnplug) != nil {
            stopOnUnplug = defaults.bool(forKey: Keys.stopOnUnplug)
        } else {
            stopOnUnplug = false
        }

        let langRaw = defaults.string(forKey: Keys.language) ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: langRaw) ?? .system

        return SessionConfig(
            mode: mode,
            durationMinutes: durationMinutes,
            customMinutes: customMinutes,
            lockOnStart: lockOnStart,
            allowClosedLid: allowClosedLid,
            batteryThresholdPercent: batteryThreshold,
            stopOnUnplug: stopOnUnplug,
            language: language
        )
    }

    public func save(_ config: SessionConfig) {
        defaults.set(config.mode.rawValue, forKey: Keys.mode)
        defaults.set(config.durationMinutes, forKey: Keys.durationMinutes)
        defaults.set(config.customMinutes, forKey: Keys.customMinutes)
        defaults.set(config.lockOnStart, forKey: Keys.lockOnStart)
        defaults.set(config.allowClosedLid, forKey: Keys.allowClosedLid)
        defaults.set(config.batteryThresholdPercent, forKey: Keys.batteryThreshold)
        defaults.set(config.stopOnUnplug, forKey: Keys.stopOnUnplug)
        defaults.set(config.language.rawValue, forKey: Keys.language)
    }
}
