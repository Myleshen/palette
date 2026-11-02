import AppKit
import Foundation

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let rect = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: alpha
    )
}

// Squircle background with a soft vertical gradient.
let radius: CGFloat = 226
let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: radius, yRadius: radius)
ctx.saveGState()
shape.addClip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color("#2c1b28").cgColor, color("#1b1018").cgColor, color("#150c13").cgColor] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: []
)
// Inner top highlight.
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color("#ffacea", 0.18).cgColor, color("#ffacea", 0).cgColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: rect.midX, y: rect.maxY - 80), startRadius: 0,
    endCenter: CGPoint(x: rect.midX, y: rect.maxY - 80), endRadius: 620,
    options: []
)
ctx.restoreGState()

// Palette card.
let card = CGRect(x: 150, y: 300, width: 724, height: 424)
let cardPath = NSBezierPath(roundedRect: card, xRadius: 92, yRadius: 92)
color("#100910", 0.78).setFill()
cardPath.fill()
color("#ffacea", 0.55).setStroke()
cardPath.lineWidth = 10
cardPath.stroke()

// Search icon inside the card.
let lens = CGRect(x: 232, y: 584, width: 118, height: 118)
let lensPath = NSBezierPath(ovalIn: lens)
color("#ffacea").setStroke()
lensPath.lineWidth = 16
lensPath.stroke()
let handle = NSBezierPath()
handle.move(to: CGPoint(x: lens.maxX - 6, y: lens.minY + 8))
handle.line(to: CGPoint(x: lens.maxX + 48, y: lens.minY - 34))
handle.lineCapStyle = .round
handle.lineWidth = 18
color("#ffacea").setStroke()
handle.stroke()

// Result bars.
for (index, width) in [330.0, 430.0, 260.0].enumerated() {
    let bar = NSBezierPath(
        roundedRect: CGRect(x: 410, y: 632 - CGFloat(index) * 84, width: width, height: 30),
        xRadius: 15, yRadius: 15
    )
    color(index == 0 ? "#ffacea" : "#ec4dd7", index == 0 ? 0.95 : 0.55).setFill()
    bar.fill()
}

// Spark accent.
let sparkCenter = CGPoint(x: 790, y: 420)
let spark = NSBezierPath()
let points: [CGPoint] = [
    CGPoint(x: sparkCenter.x, y: sparkCenter.y + 78),
    CGPoint(x: sparkCenter.x + 22, y: sparkCenter.y + 22),
    CGPoint(x: sparkCenter.x + 78, y: sparkCenter.y),
    CGPoint(x: sparkCenter.x + 22, y: sparkCenter.y - 22),
    CGPoint(x: sparkCenter.x, y: sparkCenter.y - 78),
    CGPoint(x: sparkCenter.x - 22, y: sparkCenter.y - 22),
    CGPoint(x: sparkCenter.x - 78, y: sparkCenter.y),
    CGPoint(x: sparkCenter.x - 22, y: sparkCenter.y + 22),
]
spark.move(to: points[0])
for point in points.dropFirst() { spark.line(to: point) }
spark.close()
color("#ec4dd7").setFill()
spark.fill()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) \(png.count) bytes")
