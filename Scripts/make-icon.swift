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

/// The Impuls mark, on an 18-unit grid scaled to `size`.
///
/// A transient: flat baseline, a vertical leading edge, a short plateau, then a
/// decay back to the baseline. Stroked at a constant width rather than filled
/// with a taper — a tapering silhouette loses its thin end first, and the thin
/// end was the half that carried the movement. At 16 points every part of this
/// path is the same 2 units thick, so nothing drops out.
func pulsePath(size: CGFloat, weight: CGFloat = 2.0) -> CGPath {
    let k = size / 18
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 1.6 * k, y: 5.6 * k))
    path.addLine(to: CGPoint(x: 5.9 * k, y: 5.6 * k))
    path.addLine(to: CGPoint(x: 5.9 * k, y: 15.2 * k))
    path.addLine(to: CGPoint(x: 8.6 * k, y: 15.2 * k))
    path.addCurve(
        to: CGPoint(x: 16.4 * k, y: 5.6 * k),
        control1: CGPoint(x: 11.4 * k, y: 15.2 * k),
        control2: CGPoint(x: 11.6 * k, y: 5.6 * k)
    )
    return path.copy(
        strokingWithWidth: weight * k,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )
}

/// Reads one pixel out of the master so the small sizes keep the brand colour
/// instead of a hard-coded guess that drifts the next time the icon is redrawn.
func sample(_ image: NSImage, atX x: CGFloat, y: CGFloat) -> NSColor {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
        return .black
    }
    let px = Int((CGFloat(rep.pixelsWide) * x).rounded())
    let py = Int((CGFloat(rep.pixelsHigh) * y).rounded())
    let clamped = rep.colorAt(
        x: min(max(px, 0), rep.pixelsWide - 1),
        y: min(max(py, 0), rep.pixelsHigh - 1)
    )
    return clamped?.usingColorSpace(.deviceRGB) ?? .black
}

/// The application icon at 16 and 32 points.
///
/// Downscaling the 1024-point master to 16 does not produce a small icon, it
/// produces a dark smudge: the glyph is drawn for a size where its counters are
/// tens of pixels across, and at 16 points they are a fraction of one. So the
/// small sizes are drawn rather than resampled — the brand gradient, taken from
/// the master itself, and the same pulse the menu bar carries, at a weight that
/// survives.
func drawCompactIcon(size s: CGFloat, master: NSImage) -> NSBitmapImageRep {
    let rep = bitmap(size: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Sampled off the axis the glyph sits on. The glyph occupies the middle
    // third of the master, so probing down the centre line returns the glyph's
    // own silver rather than the body colour behind it.
    let accent = sample(master, atX: 0.86, y: 0.86)   // the blue glow in the corner
    let shoulder = sample(master, atX: 0.14, y: 0.26) // the lit shoulder opposite it

    // Apple insets the icon inside its tile; matching that keeps the small
    // sizes optically the same weight as the large ones in the Dock.
    let inset = s * 0.055
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = CGPath(
        roundedRect: body,
        cornerWidth: body.width * 0.225,
        cornerHeight: body.height * 0.225,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [accent.cgColor, shoulder.cgColor] as CFArray,
        locations: [0, 1]
    ) {
        // Bottom-right to top-left, the master's own axis.
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.maxX, y: body.minY),
            end: CGPoint(x: body.minX, y: body.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    // The mark at 58% of the tile, centred, in white: at these sizes contrast
    // is the only thing that reads.
    let markSize = body.width * 0.58
    ctx.saveGState()
    ctx.translateBy(x: body.midX - markSize / 2, y: body.midY - markSize / 2)
    ctx.addPath(pulsePath(size: markSize, weight: 2.4))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// `points` is the logical size the slot stands for, `s` the pixels it is drawn
/// at. The choice between the master and the drawn mark belongs to the logical
/// size: deciding it on pixels put 32 pt @1x on the drawn mark and 32 pt @2x on
/// the master, so the same icon changed depending on whether the display was
/// Retina.
func drawIcon(size s: CGFloat, points: CGFloat, master: NSImage) -> NSBitmapImageRep {
    guard points > 32 else { return drawCompactIcon(size: s, master: master) }
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

    // A template image: pure black plus alpha. macOS recolours it for light and
    // dark menu bars, for the highlighted state, and for the tinted appearance,
    // so any colour written here would be thrown away.
    ctx.addPath(pulsePath(size: s))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (points, size, name) in [
    (16, 16, "icon_16x16"), (16, 32, "icon_16x16@2x"),
    (32, 32, "icon_32x32"), (32, 64, "icon_32x32@2x"),
    (128, 128, "icon_128x128"), (128, 256, "icon_128x128@2x"),
    (256, 256, "icon_256x256"), (256, 512, "icon_256x256@2x"),
    (512, 512, "icon_512x512"), (512, 1024, "icon_512x512@2x")
] {
    let rep = drawIcon(size: CGFloat(size), points: CGFloat(points), master: masterIcon)
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }

if let statusPath {
    let data = drawStatus(size: 54).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: statusPath))
}

print("wrote \(outPath)" + (statusPath.map { " and \($0)" } ?? ""))
