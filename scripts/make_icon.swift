#!/usr/bin/env swift  // Generates exact-size macOS icons from Micropod's editable pod/terminal master.
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/micropod-icon"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source =
    CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : root.appendingPathComponent("assets/logo/Micropod-uplift.svg")
let directory = URL(fileURLWithPath: output)
let iconset = directory.appendingPathComponent("Micropod.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let artwork = NSImage(contentsOf: source) else {
    fputs("Could not load icon master: \(source.path)\n", stderr)
    exit(1)
}
let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for (points, scale) in sizes {
    let pixels = points * scale
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fatalError("Could not allocate icon bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    context.cgContext.clear(rect)
    artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon bitmap")
    }
    let suffix = scale == 2 ? "@2x" : ""
    try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
let destination = directory.appendingPathComponent("Micropod.icns")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil could not create the icon archive. PNG masters remain in \(iconset.path).\n", stderr)
    exit(1)
}
print(destination.path)
