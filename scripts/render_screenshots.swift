import Cocoa
import Foundation
import SwiftUI

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

        let manager = SessionManager(store: store)
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
        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-settings-light.png"
        )

        manager.showSettings = false
        manager.isRunning = false
        manager.config.language = .en
        render(
            view: SleepGuardPopoverView(manager: manager),
            appearance: .aqua,
            outPath: "\(outDir)/preview-idle-en.png"
        )
    }
}
