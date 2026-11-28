#!/usr/bin/env swift
// Fails an evidence image that is uniform (a blank or single-colour render).
// Usage: image-variance.swift <png>
// Prints "<width>x<height> unique=<n> stddev=<s>". Exit 1 when uniform.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: image-variance.swift image.png\n".utf8))
    exit(2)
}
guard let data = FileManager.default.contents(atPath: args[1]),
      let source = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(2)
}
let width = source.pixelsWide
let height = source.pixelsHigh
guard width > 0, height > 0 else { exit(2) }

// 300px is enough to tell a rendered surface from a blank one and keeps a
// 6880px-wide deck snapshot cheap to sample.
let targetWidth = min(300, width)
let targetHeight = max(1, Int(Double(height) * Double(targetWidth) / Double(width)))
guard let target = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: targetWidth,
    pixelsHigh: targetHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: target) else { exit(2) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSGraphicsContext.current?.imageInterpolation = .high
source.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
NSGraphicsContext.restoreGraphicsState()

var sum = 0.0
var sumSquares = 0.0
var samples = 0
var colours = Set<Int>()
for y in stride(from: 0, to: targetHeight, by: 2) {
    for x in stride(from: 0, to: targetWidth, by: 2) {
        guard let colour = target.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let r = colour.redComponent
        let g = colour.greenComponent
        let b = colour.blueComponent
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        sum += luminance
        sumSquares += luminance * luminance
        samples += 1
        let key = (Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31)
        colours.insert(key)
    }
}
guard samples > 0 else { exit(2) }
let mean = sum / Double(samples)
let variance = max(0, sumSquares / Double(samples) - mean * mean)
let stddev = variance.squareRoot()
let unique = colours.count
print(String(format: "%dx%d unique=%d stddev=%.4f", width, height, unique, stddev))
exit(stddev < 0.01 || unique < 16 ? 1 : 0)
