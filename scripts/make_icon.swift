#!/usr/bin/env swift
// Generates Resources/AppIcon.icns.
// Draws the icon with CoreGraphics at every size macOS expects, writes an
// .iconset, and runs iconutil. Re-run after tweaking the drawing code.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent().deletingLastPathComponent()   // scripts/ -> repo root
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
let icns = resources.appendingPathComponent("AppIcon.icns")

func draw(size: CGFloat) -> CGImage {
    let px = Int(size)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = size / 1024          // scale factor so all geometry is authored on a 1024 grid

    // macOS icon grid: the rounded square sits inside a 1024 canvas with ~10% margin.
    let inset: CGFloat = 100 * s
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow beneath the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.35, green: 0.2, blue: 0.7, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient background: violet -> deep indigo.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        CGColor(red: 0.62, green: 0.36, blue: 0.98, alpha: 1),
        CGColor(red: 0.30, green: 0.16, blue: 0.72, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Subtle highlight in the top-left for a bit of depth.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.2),
                           startRadius: 0, endCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.2),
                           endRadius: rect.width * 0.9, options: [])
    ctx.restoreGState()

    // Glyph: five waveform bars; the tall centre bar extends down into a download arrow.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let cx = size / 2
    let barW = 76 * s
    let gap = 50 * s
    let heights: [CGFloat] = [160, 280, 400, 280, 160].map { $0 * s }
    let barsCenterY = size * 0.615
    let arrowTipY = size * 0.235
    let count = CGFloat(heights.count)
    let totalW = count * barW + (count - 1) * gap
    var x = cx - totalW / 2
    for (i, h) in heights.enumerated() {
        var bar = CGRect(x: x, y: barsCenterY - h / 2, width: barW, height: h)
        if i == heights.count / 2 {
            // Centre bar runs from its normal top all the way down to the arrow tip.
            bar = CGRect(x: x, y: arrowTipY, width: barW, height: bar.maxY - arrowTipY)
        }
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }

    // Arrowhead chevron attached to the bottom of the centre bar.
    ctx.setLineWidth(barW)
    let head = 120 * s
    let tip = CGPoint(x: cx, y: arrowTipY + barW / 2)
    ctx.move(to: CGPoint(x: cx - head, y: tip.y + head))
    ctx.addLine(to: tip)
    ctx.addLine(to: CGPoint(x: cx + head, y: tip.y + head))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (base size, scale) pairs iconutil expects.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (base, scale) in variants {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@\(scale)x.png"
    try writePNG(draw(size: CGFloat(base * scale)), to: iconset.appendingPathComponent(name))
}
// A 1024 preview next to the icns for README/screenshots.
try writePNG(draw(size: 1024), to: resources.appendingPathComponent("AppIcon-preview.png"))

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)
print("✓ wrote \(icns.path)")
