import Foundation

public final class PreferencesStore {
    private enum Keys {
        static let mode = "sleepskip.mode"
        static let durationMinutes = "sleepskip.durationMinutes"
        static let customMinutes = "sleepskip.customMinutes"
        static let lockOnStart = "sleepskip.lockOnStart"
        static let allowClosedLid = "sleepskip.allowClosedLid"
        static let batteryThreshold = "sleepskip.batteryThresholdPercent"
        static let stopOnUnplug = "sleepskip.stopOnUnplug"
        static let autoFollowAgents = "sleepskip.autoFollowAgents"
        static let language = "sleepskip.language"
        static let hasShownOnboarding = "sleepskip.hasShownOnboarding"
        static let hasSeenAutoFollowNotice = "sleepskip.hasSeenAutoFollowNotice"
        static let didMigrateFromSleepGuard = "sleepskip.didMigrateFromSleepGuard"

        /// Key names used by SleepGuard before the 1.2.0 rename.
        static func legacyKey(for key: String) -> String {
            key.replacingOccurrences(of: "sleepskip.", with: "sleepguard.")
        }
    }

    /// Preference domain used before the rename. Kept so upgrades keep their settings.
    public static let legacySuiteName = "io.github.laiyongqiang.SleepGuard"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "io.github.laiyongqiang.SleepSkip") ?? .standard) {
        self.defaults = defaults
    }

    /// Copies settings from the pre-rename preference domain, once.
    ///
    /// Renaming the bundle identifier moves the app to a fresh preferences domain, which would
    /// otherwise reset the user's mode, duration, language and launch-at-login preference on
    /// upgrade. Existing values always win; the legacy domain is never written to.
    public static func migrateFromLegacyDomainIfNeeded(
        defaults: UserDefaults,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacySuiteName)
    ) {
        guard let legacyDefaults, !defaults.bool(forKey: Keys.didMigrateFromSleepGuard) else { return }
        defer { defaults.set(true, forKey: Keys.didMigrateFromSleepGuard) }

        // An existing install that already has settings should not be overwritten by stale ones.
        let hasCurrentSettings = defaults.object(forKey: Keys.mode) != nil
        guard !hasCurrentSettings else { return }

        let keys = [
            Keys.mode, Keys.durationMinutes, Keys.customMinutes, Keys.lockOnStart,
            Keys.allowClosedLid, Keys.batteryThreshold, Keys.stopOnUnplug,
            Keys.autoFollowAgents, Keys.language,
        ]
        for key in keys {
            if let value = legacyDefaults.object(forKey: Keys.legacyKey(for: key)) {
                defaults.set(value, forKey: key)
            }
        }
        if let onboarding = legacyDefaults.object(forKey: Keys.legacyKey(for: Keys.hasShownOnboarding)) {
            defaults.set(onboarding, forKey: Keys.hasShownOnboarding)
        }
    }

    public var hasShownOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasShownOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasShownOnboarding) }
    }

    public var hasSeenAutoFollowNotice: Bool {
        get { defaults.bool(forKey: Keys.hasSeenAutoFollowNotice) }
        set { defaults.set(newValue, forKey: Keys.hasSeenAutoFollowNotice) }
    }

    public func load() -> SessionConfig {
        let modeRaw = defaults.string(forKey: Keys.mode) ?? GuardMode.background.rawValue
        let mode = GuardMode(rawValue: modeRaw) ?? .background

        let durationMinutes: Double
        if let stored = defaults.object(forKey: Keys.durationMinutes) as? Double {
            // 0 means "indefinite"; anything non-finite or negative falls back to the default.
            durationMinutes = stored == 0 ? 0 : (CommandBuilder.sanitizeMinutes(stored) ?? 240)
        } else {
            durationMinutes = 240
        }

        let customMinutes: Double
        if let stored = defaults.object(forKey: Keys.customMinutes) as? Double {
            customMinutes = CommandBuilder.sanitizeMinutes(stored) ?? 90
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

        // On by default: the product promise is that the app works without being configured.
        // Anyone who has ever flipped the switch has a stored value and keeps their choice.
        let autoFollowAgents: Bool
        if defaults.object(forKey: Keys.autoFollowAgents) != nil {
            autoFollowAgents = defaults.bool(forKey: Keys.autoFollowAgents)
        } else {
            autoFollowAgents = true
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
            autoFollowAgents: autoFollowAgents,
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
        defaults.set(config.autoFollowAgents, forKey: Keys.autoFollowAgents)
        defaults.set(config.language.rawValue, forKey: Keys.language)
    }
}
