// Generates Resources/AppIcon.icns from code, so the artwork lives in the
// repository as source rather than as a binary nobody can edit.
//
//   swift scripts/make-icon.swift
//
// Drawn to match the menu bar icon: a flat housing with the ball standing
// proud of it, on the graphite body colour of the device itself.

import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let u = size / 1024  // everything below is authored at 1024pt

        // macOS icons sit on a rounded square with a generous margin.
        let plate = rect.insetBy(dx: 100 * u, dy: 100 * u)
        let squircle = NSBezierPath(roundedRect: plate,
                                    xRadius: 185 * u, yRadius: 185 * u)
        NSGradient(colors: [
            NSColor(calibratedWhite: 0.28, alpha: 1),
            NSColor(calibratedWhite: 0.13, alpha: 1),
        ])?.draw(in: squircle, angle: -90)

        // Housing: deliberately shorter than the ball, square corners.
        let housingHeight = 300 * u
        let housing = NSRect(x: plate.minX + 70 * u,
                             y: plate.midY - housingHeight / 2,
                             width: plate.width - 140 * u,
                             height: housingHeight)
        NSColor(calibratedWhite: 0.62, alpha: 1).setStroke()
        let outline = NSBezierPath(rect: housing)
        outline.lineWidth = 26 * u
        outline.stroke()

        // Ball, filled last so it covers the outline and reads as on top.
        let diameter = 470 * u
        let ball = NSRect(x: plate.midX - diameter / 2,
                          y: plate.midY - diameter / 2,
                          width: diameter, height: diameter)
        NSGradient(colors: [
            NSColor(calibratedWhite: 0.97, alpha: 1),
            NSColor(calibratedWhite: 0.55, alpha: 1),
        ])?.draw(in: NSBezierPath(ovalIn: ball), angle: -90)

        // A small highlight sells it as a sphere rather than a disc.
        let gloss = NSRect(x: ball.minX + diameter * 0.22,
                           y: ball.minY + diameter * 0.58,
                           width: diameter * 0.34, height: diameter * 0.20)
        NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
        NSBezierPath(ovalIn: gloss).fill()

        return true
    }
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let projectDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                     ? CommandLine.arguments[1]
                     : FileManager.default.currentDirectoryPath)
let iconset = projectDir.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// name in the iconset -> pixel size
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    try png(drawIcon(size: CGFloat(pixels)), pixels)
        .write(to: iconset.appendingPathComponent("\(name).png"))
}

let icns = projectDir.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
print(icns.path)
