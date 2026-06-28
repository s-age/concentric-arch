#!/usr/bin/env swift
//
// generate_icon.swift — build the macOS app icon (AppIcon.icns) from a single
// full-bleed source PNG.
//
// Usage:  swift Scripts/generate_icon.swift <source.png> <output.icns> [work-dir]
//
// Reads the source artwork, fits it into the macOS Big Sur icon grid (the colored
// body is inset to 824/1024 of the canvas, leaving the transparent margin the
// system shadow expects), clips it to a continuous-corner ("squircle") rounded
// rect, emits every iconset slot, and runs `iconutil` to produce the .icns.
//
// If the source file is absent the script warns and exits 0 so a plain build can
// proceed without an icon (the app then shows the generic default icon).
//

import AppKit
import Foundation

// MARK: - Args

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: generate_icon.swift <source.png> <output.icns> [work-dir]\n".utf8))
    exit(2)
}
let sourcePath = args[1]
let outputICNS = args[2]
let workDir = args.count >= 4 ? args[3] : NSTemporaryDirectory()

func warn(_ message: String) {
    FileHandle.standardError.write(Data("[WARN] \(message)\n".utf8))
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[ERROR] \(message)\n".utf8))
    exit(1)
}

guard FileManager.default.fileExists(atPath: sourcePath) else {
    warn("\(sourcePath) not found; skipping icon generation (app will use the default icon)")
    exit(0)
}

guard let nsImage = NSImage(contentsOfFile: sourcePath),
      let source = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("cannot decode source image at \(sourcePath)")
}

// MARK: - Rendering

// macOS Big Sur icon grid: on a 1024 canvas the rounded body is 824×824 with a
// 185.4 pt continuous corner radius. Keep those ratios at every size.
let bodyRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.4 / 824.0

func renderPNG(pixelSize: Int) -> Data? {
    let canvas = CGFloat(pixelSize)
    let body = (canvas * bodyRatio).rounded()
    let origin = ((canvas - body) / 2).rounded()
    let radius = body * cornerRatio
    let bodyRect = CGRect(x: origin, y: origin, width: body, height: body)

    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high

    // Continuous-corner squircle mask via CALayer (honored by render(in:) on
    // macOS 12+). The layer's contents are aspect-fill scaled into the body rect.
    let layer = CALayer()
    layer.anchorPoint = .zero
    layer.bounds = CGRect(x: 0, y: 0, width: body, height: body)
    layer.position = bodyRect.origin
    layer.contents = source
    layer.contentsGravity = .resizeAspectFill
    layer.masksToBounds = true
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous

    ctx.translateBy(x: bodyRect.minX, y: bodyRect.minY)
    layer.render(in: ctx)

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Iconset

// (filename, pixel size) — the full macOS .icns ladder.
let slots: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
let iconsetDir = (workDir as NSString).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(atPath: iconsetDir)
do {
    try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
} catch {
    fail("cannot create iconset dir: \(error.localizedDescription)")
}

for (name, size) in slots {
    guard let png = renderPNG(pixelSize: size) else {
        fail("failed to render \(name)")
    }
    let path = (iconsetDir as NSString).appendingPathComponent(name)
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("cannot write \(path): \(error.localizedDescription)")
    }
}

// MARK: - iconutil

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", outputICNS]
do {
    try proc.run()
    proc.waitUntilExit()
} catch {
    fail("failed to launch iconutil: \(error.localizedDescription)")
}
guard proc.terminationStatus == 0 else {
    fail("iconutil exited with status \(proc.terminationStatus)")
}

try? fm.removeItem(atPath: iconsetDir)
print("[INFO] wrote \(outputICNS)")
