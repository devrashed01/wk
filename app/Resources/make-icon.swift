// Draws Wk's app icon and writes AppIcon.icns next to this file.
// Run: swift app/Resources/make-icon.swift   (needs iconutil, which ships with macOS)
import AppKit

let canvas: CGFloat = 1024

let space = CGColorSpaceCreateDeviceRGB()

/// A restrained, Terminal-style icon: near-black tile, one precise branch glyph.
/// Geometry follows icon-font construction rules: uniform 58pt stroke, ring nodes of equal
/// radius, tangent joins, and the glyph held to ~55% of the tile with true optical centering.
func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824pt tile centered on a 1024pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft drop shadow (Finder adds its own; this keeps the standalone preview honest).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Barely-there vertical gradient, graphite to near-black.
    let background = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.125, green: 0.137, blue: 0.165, alpha: 1).cgColor,
        NSColor(red: 0.051, green: 0.055, blue: 0.071, alpha: 1).cgColor,
    ] as CFArray, locations: nil)!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Corner vignette, machined rather than lit.
    let vignette = CGGradient(colorsSpace: space, colors: [
        NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.16).cgColor,
    ] as CFArray, locations: nil)!
    ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: 512, y: 512), startRadius: 240,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 620, options: [])
    // Hairline top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.07).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: nil)!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.midY + 120), options: [])
    ctx.restoreGState()

    // Inner hairline edge.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // The mark: one trunk, two worktrees peeling off it; the live checkout is orange.
    // Construction rules: uniform 58pt stroke, round caps, quarter-ellipse peels that leave the
    // trunk on a vertical tangent and finish horizontal, glyph held to ~55% of the tile.
    let white = NSColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1).cgColor
    let orange = NSColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1).cgColor  // systemOrange (dark)
    let k: CGFloat = 0.5523
    let trunkX: CGFloat = 360

    func peel(from a: CGPoint, to b: CGPoint) {
        ctx.move(to: a)
        ctx.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + k * (b.y - a.y)),
                     control2: CGPoint(x: b.x - k * (b.x - a.x), y: b.y))
        ctx.strokePath()
    }

    ctx.saveGState()
    // Hold the glyph to ~55% of the tile.
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 0.70, y: 0.70); ctx.translateBy(x: -512, y: -512)
    ctx.setLineWidth(58)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(white)
    ctx.move(to: CGPoint(x: trunkX, y: 268))
    ctx.addLine(to: CGPoint(x: trunkX, y: 756))
    ctx.strokePath()
    peel(from: CGPoint(x: trunkX, y: 330), to: CGPoint(x: 664, y: 520))
    ctx.setStrokeColor(orange)
    peel(from: CGPoint(x: trunkX, y: 510), to: CGPoint(x: 664, y: 700))
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx.cgContext)
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let preview = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-preview.png")
try png(size: 1024).write(to: preview)
print("Preview: \(preview.path)")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
