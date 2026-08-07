#!/usr/bin/env swift
// Generates the macOS application icon and its matching menu-bar mark.
// The symbol combines the two initials of «Интегра Импульс» with a pulse.
// Usage: swift Scripts/make-icon.swift <output.icns> [status-template.png]
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let statusPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
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

func drawBrandMark(in ctx: CGContext, scale k: CGFloat, monochrome: Bool = false) {
    let white = monochrome
        ? CGColor(gray: 0, alpha: 1)
        : CGColor(red: 0.97, green: 0.99, blue: 1, alpha: 1)
    let pulse = monochrome
        ? CGColor(gray: 0, alpha: 1)
        : CGColor(red: 0.23, green: 0.91, blue: 1, alpha: 1)

    // Twin pillars: the two words share one stable corporate monogram.
    for x in [CGFloat(318), CGFloat(634)] {
        let rect = CGRect(x: x * k, y: 300 * k, width: 72 * k, height: 424 * k)
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: 36 * k,
            cornerHeight: 36 * k,
            transform: nil
        ))
        ctx.setFillColor(white)
        ctx.fillPath()
    }

    // The connecting impulse turns the initials into one integrated symbol.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 382 * k, y: 500 * k))
    path.addLine(to: CGPoint(x: 448 * k, y: 500 * k))
    path.addLine(to: CGPoint(x: 490 * k, y: 616 * k))
    path.addLine(to: CGPoint(x: 536 * k, y: 396 * k))
    path.addLine(to: CGPoint(x: 579 * k, y: 500 * k))
    path.addLine(to: CGPoint(x: 642 * k, y: 500 * k))
    ctx.addPath(path)
    ctx.setStrokeColor(pulse)
    ctx.setLineWidth(42 * k)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let rep = bitmap(size: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024

    let body = CGRect(x: 92 * k, y: 92 * k, width: 840 * k, height: 840 * k)
    let squircle = CGPath(
        roundedRect: body,
        cornerWidth: 190 * k,
        cornerHeight: 190 * k,
        transform: nil
    )

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * k), blur: 46 * k, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.04, green: 0.07, blue: 0.15, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.18, green: 0.28, blue: 0.66, alpha: 1),
            CGColor(red: 0.05, green: 0.09, blue: 0.22, alpha: 1),
            CGColor(red: 0.025, green: 0.04, blue: 0.10, alpha: 1)
        ] as CFArray,
        locations: [0, 0.58, 1]
    )!
    ctx.drawLinearGradient(
        background,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )

    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.20, green: 0.88, blue: 1, alpha: 0.22),
            CGColor(red: 0.20, green: 0.88, blue: 1, alpha: 0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 300 * k, y: 770 * k),
        startRadius: 0,
        endCenter: CGPoint(x: 300 * k, y: 770 * k),
        endRadius: 570 * k,
        options: []
    )

    drawBrandMark(in: ctx, scale: k)
    ctx.restoreGState()

    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(3 * k)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawStatus(size s: CGFloat) -> NSBitmapImageRep {
    let rep = bitmap(size: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 18

    for x in [CGFloat(3.1), CGFloat(12.6)] {
        let rect = CGRect(x: x * k, y: 2.8 * k, width: 2.2 * k, height: 12.4 * k)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 1.1 * k, cornerHeight: 1.1 * k, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
    }

    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 5.0 * k, y: 9.0 * k))
    pulse.addLine(to: CGPoint(x: 7.0 * k, y: 9.0 * k))
    pulse.addLine(to: CGPoint(x: 8.1 * k, y: 12.2 * k))
    pulse.addLine(to: CGPoint(x: 9.5 * k, y: 5.7 * k))
    pulse.addLine(to: CGPoint(x: 10.8 * k, y: 9.0 * k))
    pulse.addLine(to: CGPoint(x: 12.9 * k, y: 9.0 * k))
    ctx.addPath(pulse)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setLineWidth(1.55 * k)
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
    let data = drawIcon(size: CGFloat(size)).representation(using: .png, properties: [:])!
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
