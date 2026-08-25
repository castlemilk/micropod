#!/usr/bin/env swift
// Generates a native Micropod app icon: gradient rounded square + SF
// symbol "shippingbox.fill" (and "point.3.filled.trianglepath.dotted" motif)
// at every needed size, then builds an .icns via iconutil.
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/micropod-icon"
let iconsetDir = URL(fileURLWithPath: outDir).appendingPathComponent("Micropod.iconset")
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Rounded-rect gradient background (macOS app-icon convention: fully
    // rounded rect, no transparency at the outer bounds).
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.93, alpha: 1),   // blue
            NSColor(calibratedRed: 0.10, green: 0.31, blue: 0.72, alpha: 1),   // deep blue
        ])!
    gradient.draw(in: path, angle: -70)

    // Subtle top sheen.
    NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
    let sheen = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02),
                             xRadius: radius * 0.95, yRadius: radius * 0.95)
    sheen.addClip()
    NSRect(x: 0, y: size * 0.72, width: size, height: size * 0.30).fill()

    // SF Symbol: shippingbox.fill, white, centered.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    {
        let symbolRect = NSRect(
            x: (size - symbol.size.width) / 2,
            y: (size - symbol.size.height) / 2,
            width: symbol.size.width, height: symbol.size.height)
        NSColor.white.set()
        symbol.draw(in: symbolRect)
    }

    image.unlockFocus()
    return image
}

// All standard icon sizes.
let sizes: [(pixels: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for (pixels, scale) in sizes {
    let name = "icon_\(pixels)x\(pixels)\(scale == 2 ? "@2x" : "").png"
    let url = iconsetDir.appendingPathComponent(name)
    let image = drawIcon(size: CGFloat(pixels * scale))
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("failed to render \(name)\n", stderr)
        exit(1)
    }
    try? png.write(to: url)
}

// Build the .icns.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", "\(outDir)/Micropod.icns"]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("\(outDir)/Micropod.icns")
