#!/usr/bin/env swift
// Writes a small varied PNG so wallpaper/clipboard/preview fixtures are real
// pictures instead of blank rectangles.
// Usage: evidence-fixture.swift <out.png> <width> <height> <hue 0..1>
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 5,
      let width = Double(args[2]), let height = Double(args[3]),
      let hue = Double(args[4]), width > 0, height > 0 else {
    FileHandle.standardError.write(Data("usage: evidence-fixture.swift out.png width height hue\n".utf8))
    exit(2)
}
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(2) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let rect = NSRect(x: 0, y: 0, width: width, height: height)
let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.82, alpha: 1)
let bottom = NSColor(
    hue: (hue + 0.22).truncatingRemainder(dividingBy: 1),
    saturation: 0.85,
    brightness: 0.28,
    alpha: 1
)
NSGradient(colors: [top, bottom])?.draw(in: rect, angle: -35)
for index in 0..<7 {
    let inset = CGFloat(index) * 34 + 30
    NSColor.white.withAlphaComponent(0.10).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: inset,
        y: CGFloat(height) * 0.28 + inset * 0.4,
        width: CGFloat(width) * 0.45,
        height: CGFloat(height) * 0.45
    )).fill()
}
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(2) }
try data.write(to: URL(fileURLWithPath: args[1]), options: .atomic)
