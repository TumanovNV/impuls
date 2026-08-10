#!/usr/bin/env swift
// Generates the macOS application icon and its matching menu-bar mark.
// The full-resolution master is the single source of truth for every app size.
// Usage: swift Scripts/make-icon.swift <master.png> <output.icns> [status-template.png]
import AppKit

guard CommandLine.arguments.count >= 3 else {
    fatalError("usage: make-icon.swift <master.png> <output.icns> [status-template.png]")
}

let masterPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let statusPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
guard let masterIcon = NSImage(contentsOfFile: masterPath) else {
    fatalError("cannot read application icon master: \(masterPath)")
}
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Impuls.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func bitmap(size s: CGFloat) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(s),
        pixelsHigh: Int(s),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
}

func drawIcon(size s: CGFloat, master: NSImage) -> NSBitmapImageRep {
    let rep = bitmap(size: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!
    context.cgContext.clear(CGRect(x: 0, y: 0, width: s, height: s))
    master.draw(
        in: NSRect(x: 0, y: 0, width: s, height: s),
        from: NSRect(origin: .zero, size: master.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawStatus(size s: CGFloat) -> NSBitmapImageRep {
    let rep = bitmap(size: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 18

    // The menu bar gets the essence of the brand rather than a miniature app
    // icon: one rising, tapered pulse. A single unbroken silhouette preserves
    // the upward movement at 18 points and avoids reading as a loop or spiral.
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 2.15 * k, y: 2.25 * k))
    pulse.addLine(to: CGPoint(x: 5.45 * k, y: 2.25 * k))
    pulse.addCurve(
        to: CGPoint(x: 15.75 * k, y: 15.75 * k),
        control1: CGPoint(x: 9.15 * k, y: 2.25 * k),
        control2: CGPoint(x: 13.65 * k, y: 8.35 * k)
    )
    pulse.addLine(to: CGPoint(x: 15.75 * k, y: 12.35 * k))
    pulse.addCurve(
        to: CGPoint(x: 8.95 * k, y: 5.45 * k),
        control1: CGPoint(x: 13.85 * k, y: 10.05 * k),
        control2: CGPoint(x: 11.05 * k, y: 6.45 * k)
    )
    pulse.addCurve(
        to: CGPoint(x: 5.45 * k, y: 4.45 * k),
        control1: CGPoint(x: 7.55 * k, y: 4.75 * k),
        control2: CGPoint(x: 6.35 * k, y: 4.45 * k)
    )
    pulse.addLine(to: CGPoint(x: 2.15 * k, y: 4.45 * k))
    pulse.closeSubpath()
    ctx.addPath(pulse)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
] {
    let data = drawIcon(size: CGFloat(size), master: masterIcon).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }

if let statusPath {
    let data = drawStatus(size: 36).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: statusPath))
}

print("wrote \(outPath)" + (statusPath.map { " and \($0)" } ?? ""))
