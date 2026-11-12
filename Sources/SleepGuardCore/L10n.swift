import Foundation

public struct L10n {
    public let isZh: Bool

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.isZh = language.resolvedIsChinese(preferredLanguages: preferredLanguages)
    }

    public var appName: String { isZh ? "防休眠助手" : "SleepGuard" }
    public var idleBadge: String { isZh ? "待机" : "Idle" }
    public var runningBadge: String { isZh ? "运行中" : "Active" }
    public var backpackBadge: String { isZh ? "背包运行中" : "Backpack" }

    public var notRunningTitle: String { isZh ? "当前未运行" : "Not Running" }
    public var runningTitle: String { isZh ? "正在保持唤醒" : "Keeping Awake" }
    public var indefiniteRunning: String { isZh ? "持续运行" : "Indefinite" }

    public var modeSectionTitle: String { isZh ? "运行模式" : "Mode" }
    public var durationSectionTitle: String { isZh ? "持续时间" : "Duration" }

    public func modeTitle(_ mode: GuardMode) -> String {
        switch mode {
        case .background: return isZh ? "后台运行" : "Background"
        case .keepDisplay: return isZh ? "屏幕常亮" : "Keep Display On"
        }
    }

    public func modeSubtitle(_ mode: GuardMode) -> String {
        switch mode {
        case .background:
            return isZh ? "防止空闲休眠，允许息屏（Codex CLI / 编译）" : "Prevent idle sleep, allow display off"
        case .keepDisplay:
            return isZh ? "防止休眠和息屏（Computer Use / 演示）" : "Keep system and display awake"
        }
    }

    public var modeRecommendedBadge: String { isZh ? "省电推荐" : "Battery Saver" }
    public var modeTipBackground: String { isZh ? "续航最优" : "Best battery" }
    public var modeTipDisplay: String { isZh ? "建议调暗亮度" : "Lower brightness to save power" }

    public var lockOnStartLabel: String { isZh ? "启动即锁屏" : "Lock on start" }
    public var closedLidLabel: String { isZh ? "合盖继续运行（背包）" : "Stay awake lid-closed" }
    public var closedLidWarning: String {
        isZh
            ? "需 Touch ID 授权 · 停止或退出时自动恢复休眠 · 注意背包散热"
            : "Requires Touch ID auth · Auto-restores sleep on exit · Watch thermals"
    }

    public var customDuration: String { isZh ? "自定义" : "Custom" }
    public var minutesUnit: String { isZh ? "分钟" : "min" }
    public var applyButton: String { isZh ? "应用" : "Apply" }
    public var startButton: String { isZh ? "开始保持唤醒 (⏎)" : "Start Keeping Awake (⏎)" }
    public var stopButton: String { isZh ? "停止" : "Stop" }
    public var extend30mButton: String { isZh ? "+ 延长 30 分钟" : "+30 min" }
    public var lockScreenButton: String { isZh ? "锁定屏幕" : "Lock Screen" }
    public var quitButton: String { isZh ? "退出应用" : "Quit" }

    public func currentSettingLabel(_ text: String) -> String {
        isZh ? "本次设置：\(text)" : "Duration: \(text)"
    }

    public func projectedEndLabel(_ time: String) -> String {
        isZh ? "预计 \(time) 结束" : "Ends around \(time)"
    }

    public func cliGuardingBanner(_ cli: ExternalCLISession) -> String {
        isZh
            ? "CLI 守护中：\(cli.commandName) (PID \(cli.pid))"
            : "CLI Guarding: \(cli.commandName) (PID \(cli.pid))"
    }

    public func lastConfigSummary(_ config: SessionConfig) -> String {
        let modeTxt = isZh
            ? (config.mode == .background ? "后台" : "常亮")
            : (config.mode == .background ? "Background" : "Display On")
        let lockTxt = config.effectiveLockOnStart ? (isZh ? "+锁屏" : "+Lock") : ""
        let lidTxt = config.effectiveAllowClosedLid ? (isZh ? "+合盖" : "+Lid") : ""
        let durTxt = DurationFormatter.formatDuration(config.durationMinutes, isChinese: isZh)
        return isZh
            ? "上次配置：\(modeTxt)\(lockTxt)\(lidTxt) · \(durTxt)（按 ⏎ 直启）"
            : "Last: \(modeTxt)\(lockTxt)\(lidTxt) · \(durTxt) (Press ⏎)"
    }

    public var staleSleepDisabledBanner: String {
        isZh ? "检测到系统合盖休眠处于禁用状态" : "System lid-close sleep is currently disabled"
    }
    public var restoreSleepButton: String { isZh ? "立即恢复" : "Restore" }

    public func lowBatteryBlockedError(current: Int, threshold: Int) -> String {
        isZh
            ? "当前电量 \(current)% 已低于保护阈值 \(threshold)%，请连接电源或调整阈值"
            : "Battery is at \(current)% (cutoff \(threshold)%); connect power or adjust threshold"
    }

    public var unpluggedBlockedError: String {
        isZh
            ? "已开启「拔电时自动停止」，当前正在使用电池"
            : "Currently on battery while Stop on Unplug is enabled"
    }

    // Settings
    public var settingsTitle: String { isZh ? "偏好设置与规范" : "Preferences & Specs" }
    public var backButton: String { isZh ? "返回" : "Done" }
    public var launchAtLoginLabel: String { isZh ? "登录时自动启动" : "Launch at Login" }
    public var stopOnUnplugLabel: String { isZh ? "拔掉电源时自动停止" : "Stop when unplugged" }
    public var batteryCutoffLabel: String { isZh ? "低电量自动停止" : "Low-Battery Cutoff" }
    public var batteryCutoffOff: String { isZh ? "关闭" : "Off" }
    public var languageLabel: String { isZh ? "界面语言" : "Language" }
    public var languageSystem: String { isZh ? "跟随系统" : "System" }
    public var engineInfoTitle: String { isZh ? "底层引擎与 CLI 伴侣" : "Engine & CLI Companion" }
    public var engineInfoDetail: String {
        isZh
            ? "基于 macOS 原生 caffeinate -w <PID>，收起面板零定时器（0% CPU）。支持 sleepguard:// URL 与 CLI 守护：sleepguard -- codex。"
            : "Native caffeinate -w <PID>, zero timers when closed (0% CPU). Supports sleepguard:// URLs & CLI guard: sleepguard -- codex."
    }

    // Menu bar context menu
    public var menuOpenPanel: String { isZh ? "打开防休眠面板" : "Open Panel" }
    public var menuQuickStart: String { isZh ? "按上次配置快速开启" : "Quick Start (Last Config)" }
    public var menuStop: String { isZh ? "停止保持唤醒" : "Stop Keeping Awake" }

    // Notifications (delivered only on asynchronous background transitions)
    public var notifStoppedTitle: String { isZh ? "防休眠已自动停止" : "SleepGuard Stopped" }
    public var notifExpiredBody: String { isZh ? "预设时长已到期，系统已恢复正常休眠" : "Timer expired; normal sleep restored" }
    public var notifLowBatteryTitle: String { isZh ? "低电量自动保护" : "Low Battery Cutoff" }
    public func notifLowBatteryBody(_ pct: Int) -> String {
        isZh
            ? "电池电量已降至 \(pct)%，已自动停止防休眠并恢复系统休眠"
            : "Battery reached \(pct)%; SleepGuard stopped to protect battery"
    }
    public var notifUnpluggedTitle: String { isZh ? "电源已断开" : "Power Disconnected" }
    public var notifUnpluggedBody: String {
        isZh
            ? "检测到切换至电池供电，已自动停止防休眠"
            : "Switched to battery power; SleepGuard stopped automatically"
    }
}
