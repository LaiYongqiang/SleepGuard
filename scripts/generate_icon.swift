import Cocoa
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: generate_icon.swift <output-icns-path>\n", stderr)
    exit(1)
}

let outputIcnsPath = CommandLine.arguments[1]
let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("SleepGuardIcon-\(UUID().uuidString)")
let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset")

try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

func renderIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Subtle drop shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(squircle)
    cg.setFillColor(NSColor(red: 0.09, green: 0.12, blue: 0.19, alpha: 1.0).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Gradient background fill
    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()
    let colors = [
        NSColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0).cgColor,
        NSColor(red: 0.13, green: 0.20, blue: 0.34, alpha: 1.0).cgColor
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])

    // Subtle radial glow behind center glyph
    let glowColors = [
        NSColor(red: 0.20, green: 0.78, blue: 0.55, alpha: 0.28).cgColor,
        NSColor(red: 0.20, green: 0.78, blue: 0.55, alpha: 0.0).cgColor
    ] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0.0, 1.0])!
    cg.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: s * 0.5, y: s * 0.54),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.5, y: s * 0.54),
        endRadius: s * 0.42,
        options: []
    )
    cg.restoreGState()

    // Inner glass rim
    cg.saveGState()
    cg.addPath(squircle)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(max(1.0, s * 0.012))
    cg.strokePath()
    cg.restoreGState()

    // Center SF Symbol: cup.and.saucer.fill
    if let sym = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.38, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                NSColor(red: 0.94, green: 0.97, blue: 1.0, alpha: 1.0)
            ]))
        if let styled = sym.withSymbolConfiguration(cfg) {
            let imgSize = styled.size
            let drawRect = NSRect(
                x: (s - imgSize.width) / 2.0,
                y: (s - imgSize.height) / 2.0 - s * 0.02,
                width: imgSize.width,
                height: imgSize.height
            )
            styled.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    // Active green status dot badge at top-right of cup
    let dotRadius = s * 0.065
    let dotCenter = CGPoint(x: s * 0.71, y: s * 0.72)
    let dotRect = CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    cg.setFillColor(NSColor(red: 0.18, green: 0.82, blue: 0.46, alpha: 1.0).cgColor)
    cg.fillEllipse(in: dotRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, px) in entries {
    let rep = renderIcon(size: px)
    if let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: iconsetDir.appendingPathComponent(filename))
    }
}

let outParent = URL(fileURLWithPath: outputIcnsPath).deletingLastPathComponent()
try FileManager.default.createDirectory(at: outParent, withIntermediateDirectories: true)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", outputIcnsPath]
try task.run()
task.waitUntilExit()
if task.terminationStatus != 0 {
    exit(task.terminationStatus)
}
print("Generated \(outputIcnsPath)")
