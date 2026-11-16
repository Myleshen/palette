#!/usr/bin/env swift
// Compares two PNGs and prints the percentage of differing pixels.
// Usage: pixel-diff.swift <a.png> <b.png> [tolerance]
// Exit codes: 0 identical enough, 1 different, 2 usage/load error.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: pixel-diff.swift a.png b.png [tolerance]\n".utf8))
    exit(2)
}
let tolerance = args.count > 3 ? (Double(args[3]) ?? 0.02) : 0.02
let canonicalWidth = 900

func load(_ path: String) -> NSBitmapImageRep? {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else { return nil }
    guard rep.pixelsWide != canonicalWidth else { return rep }
    let scale = Double(canonicalWidth) / Double(rep.pixelsWide)
    let height = max(1, Int(Double(rep.pixelsHigh) * scale))
    guard let target = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canonicalWidth,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: canonicalWidth, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return target
}

guard let a = load(args[1]) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(2)
}
guard let b = load(args[2]) else {
    FileHandle.standardError.write(Data("cannot read \(args[2])\n".utf8))
    exit(2)
}
guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
    print("size \(a.pixelsWide)x\(a.pixelsHigh) vs \(b.pixelsWide)x\(b.pixelsHigh)")
    exit(1)
}

var differing = 0
let total = a.pixelsWide * a.pixelsHigh
for y in 0..<a.pixelsHigh {
    for x in 0..<a.pixelsWide {
        guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let delta = max(
            abs(ca.redComponent - cb.redComponent),
            max(abs(ca.greenComponent - cb.greenComponent), abs(ca.blueComponent - cb.blueComponent))
        )
        if delta > 0.06 { differing += 1 }
    }
}
let ratio = Double(differing) / Double(total)
print(String(format: "%.2f%% of %d pixels differ", ratio * 100, total))
exit(ratio > tolerance ? 1 : 0)
