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

// Squircle background.
let radius: CGFloat = 226
let background = NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: radius, yRadius: radius)
ctx.saveGState()
background.addClip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color("#33202d").cgColor, color("#1b1018").cgColor, color("#120b11").cgColor] as CFArray,
    locations: [0, 0.6, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: []
)
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color("#ffacea", 0.16).cgColor, color("#ffacea", 0).cgColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: rect.midX, y: rect.maxY - 80), startRadius: 0,
    endCenter: CGPoint(x: rect.midX, y: rect.maxY - 80), endRadius: 640,
    options: []
)
ctx.restoreGState()

let center = CGPoint(x: 512, y: 520)
let petalRadius: CGFloat = 205
let petalSize: CGFloat = 330

// Soft drop shadow under the palette.
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = color("#000000", 0.45)
shadow.shadowBlurRadius = 48
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
let silhouette = NSBezierPath()
for index in 0..<6 {
    let angle = Double(index) * Double.pi / 3 + Double.pi / 6
    let petalCenter = CGPoint(
        x: center.x + CGFloat(cos(angle)) * petalRadius,
        y: center.y + CGFloat(sin(angle)) * petalRadius
    )
    silhouette.append(NSBezierPath(ovalIn: NSRect(
        x: petalCenter.x - petalSize / 2,
        y: petalCenter.y - petalSize / 2,
        width: petalSize, height: petalSize
    )))
}
silhouette.append(NSBezierPath(ovalIn: NSRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380)))
color("#f6e7d8").setFill()
silhouette.fill()
ctx.restoreGState()

// Palette body: warm cream petals.
func petalPath(at petalCenter: CGPoint, size: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(
        x: petalCenter.x - size / 2,
        y: petalCenter.y - size / 2,
        width: size, height: size
    ))
}
var petals: [(CGPoint, NSColor)] = []
let dabColors = ["#ff6fae", "#ec4dd7", "#7bdcb5", "#ffd166", "#7aa2ff", "#ff9f68"]
for index in 0..<6 {
    let angle = Double(index) * Double.pi / 3 + Double.pi / 6
    let petalCenter = CGPoint(
        x: center.x + CGFloat(cos(angle)) * petalRadius,
        y: center.y + CGFloat(sin(angle)) * petalRadius
    )
    petals.append((petalCenter, color(dabColors[index])))
    let path = petalPath(at: petalCenter, size: petalSize)
    color("#f8ecdf").setFill()
    path.fill()
    color("#d8bfae", 0.55).setStroke()
    path.lineWidth = 5
    path.stroke()
}
// Center disc ties the flower together.
let disc = NSBezierPath(ovalIn: NSRect(x: center.x - 195, y: center.y - 195, width: 390, height: 390))
color("#f8ecdf").setFill()
disc.fill()
color("#d8bfae", 0.55).setStroke()
disc.lineWidth = 5
disc.stroke()

// Paint dabs on each petal.
for (petalCenter, dab) in petals {
    let dabRect = NSRect(x: petalCenter.x - 52, y: petalCenter.y - 52, width: 104, height: 104)
    dab.setFill()
    NSBezierPath(ovalIn: dabRect).fill()
    color("#ffffff", 0.45).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: dabRect.minX + 18, y: dabRect.minY + 48,
        width: 30, height: 24
    )).fill()
}

// Thumb hole: the dark background shows through the palette.
color("#1b1018").setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 74, y: center.y + 16, width: 130, height: 130)).fill()
color("#000000", 0.35).setStroke()
let hole = NSBezierPath(ovalIn: NSRect(x: center.x - 74, y: center.y + 16, width: 130, height: 130))
hole.lineWidth = 4
hole.stroke()

// Two specular highlights for a hand-painted feel.
color("#ffffff", 0.16).setFill()
NSBezierPath(ovalIn: NSRect(x: 330, y: 700, width: 190, height: 110)).fill()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) \(png.count) bytes")
