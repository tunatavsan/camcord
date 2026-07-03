#!/usr/bin/swift
// Generates Resources/AppIcon.icns. Run once (or whenever the icon design changes):
//   swift scripts/make-icon.swift
// Design: macOS-style rounded square, deep indigo->slate gradient, white
// camera.viewfinder SF Symbol. Deterministic output, no external assets.
import AppKit

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = repoRoot.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
let icnsURL = repoRoot.appendingPathComponent("Resources/AppIcon.icns")

func renderIcon(pixelSize: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixelSize)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
    else {
        fatalError("Could not create bitmap rep at \(pixelSize)px")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: content inset ~10%, corner radius ~22.37% of the shape size.
    let inset = size * 0.10
    let shapeRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = shapeRect.width * 0.2237
    let shape = NSBezierPath(roundedRect: shapeRect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.28, green: 0.24, blue: 0.55, alpha: 1),
        ending: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.20, alpha: 1)
    )
    gradient?.draw(in: shape, angle: -90)

    let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: shapeRect.width * 0.52, weight: .medium
    )
    if let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfiguration)
    {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let symbolRect = NSRect(
            x: shapeRect.midX - tinted.size.width / 2,
            y: shapeRect.midY - tinted.size.height / 2,
            width: tinted.size.width,
            height: tinted.size.height
        )
        tinted.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// (filename base points, pixel size) pairs iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in variants {
    let rep = renderIcon(pixelSize: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(name)")
    }
    try png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("Wrote \(icnsURL.path)")
