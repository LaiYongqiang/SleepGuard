import Cocoa
import Foundation
import SwiftUI

final class PreviewCaffeinate: CaffeinateRunning {
    var isActive: Bool = false
    func start(mode: GuardMode, timeoutSeconds: Int?, onUnexpectedExit: @escaping () -> Void) throws { isActive = true }
    func stop() { isActive = false }
}

final class PreviewBackpack: BackpackGuarding {
    func enable(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func disable() {}
    func checkSleepDisabledAsync(completion: @escaping (Bool) -> Void) { completion(false) }
    func restoreNormalSleepAsync(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}

final class PreviewPower: PowerMonitoring {
    func currentPowerSnapshot() -> PowerSnapshot? { PowerSnapshot(onBattery: false, percentage: 100) }
    func start(thresholdPercent: Int, stopOnUnplug: Bool, onEvent: @escaping (PowerEvent) -> Void) {}
    func stop() {}
}

final class PreviewLocker: ScreenLocking { func lockScreen() {} }
final class PreviewNotifier: UserNotifying {
    func preparePermissionIfNeeded() {}
    func send(title: String, body: String) {}
}
final class PreviewLogin: LoginItemControlling {
    var isEnabled: Bool = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@main
struct ScreenshotRenderer {
    static func render(view: some View, appearance: NSAppearance.Name, outPath: String) {
        let wrapped = view
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )

        let hosting = NSHostingView(rootView: wrapped)
        hosting.appearance = NSAppearance(named: appearance)
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 356, height: fitting.height))
        hosting.layoutSubtreeIfNeeded()

        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outPath))
                print("Rendered \(outPath) (\(Int(fitting.width))x\(Int(fitting.height)))")
            }
        }
    }

    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let tempSuite = "io.github.laiyongqiang.SleepGuard.render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: tempSuite)!
        defer { defaults.removePersistentDomain(forName: tempSuite) }
        let store = PreferencesStore(defaults: defaults)

        let manager = SessionManager(
            store: store,
            caffeinateRunner: PreviewCaffeinate(),
            backpackGuard: PreviewBackpack(),
            powerMonitor: PreviewPower(),
            screenLocker: PreviewLocker(),
            notifier: PreviewNotifier(),
            loginItem: PreviewLogin(),
            checkStaleSleepOnInit: false
        )
        manager.config.language = .zhHans
        manager.staleSleepDisabled = false
        manager.isRunning = false

        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-idle-light.png"
        )

        manager.isRunning = true
        manager.activeMode = .background
        manager.activeClosedLid = true
        manager.isIndefinite = false
        manager.initialMinutes = 240
        manager.remainingSeconds = 14356
        manager.endDate = Date().addingTimeInterval(14356)

        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-running-light.png"
        )

        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .darkAqua,
            outPath: "\(outDir)/preview-running-dark.png"
        )

        manager.showSettings = true
        manager.isRunning = false
        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-settings-light.png"
        )

        manager.showSettings = false
        manager.config.language = .en
        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-idle-en.png"
        )

        manager.isRunning = true
        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-running-light-en.png"
        )

        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .darkAqua,
            outPath: "\(outDir)/preview-running-dark-en.png"
        )

        manager.isRunning = false
        manager.showSettings = true
        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-settings-en.png"
        )
    }
}
