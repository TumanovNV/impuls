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

    // At menu-bar size chrome and shadows become visual noise, so this keeps
    // only the interlocking, rounded silhouette from the application icon.
    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 4.0 * k, y: 2.8 * k))
    mark.addLine(to: CGPoint(x: 11.5 * k, y: 2.8 * k))
    mark.addCurve(
        to: CGPoint(x: 15.0 * k, y: 6.3 * k),
        control1: CGPoint(x: 13.5 * k, y: 2.8 * k),
        control2: CGPoint(x: 15.0 * k, y: 4.3 * k)
    )
    mark.addLine(to: CGPoint(x: 15.0 * k, y: 15.2 * k))
    mark.move(to: CGPoint(x: 12.3 * k, y: 15.2 * k))
    mark.addLine(to: CGPoint(x: 12.3 * k, y: 10.9 * k))
    mark.addLine(to: CGPoint(x: 8.3 * k, y: 10.9 * k))
    mark.addCurve(
        to: CGPoint(x: 5.7 * k, y: 8.3 * k),
        control1: CGPoint(x: 6.9 * k, y: 10.9 * k),
        control2: CGPoint(x: 5.7 * k, y: 9.8 * k)
    )
    mark.addLine(to: CGPoint(x: 5.7 * k, y: 2.8 * k))
    ctx.addPath(mark)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineWidth(2.35 * k)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

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
