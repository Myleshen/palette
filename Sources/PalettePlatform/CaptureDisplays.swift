import AppKit
import CoreGraphics
import Foundation

/// Active displays, in the order `screencapture -D` numbers them.
public struct CaptureDisplay: Sendable, Equatable, Identifiable {
    public var index: Int        // 1-based, as `-D` expects
    public var name: String
    public var width: Int
    public var height: Int

    public var id: Int { index }
    public var label: String { "\(name) — \(width)×\(height)" }
}

public enum CaptureDisplays {
    public static func active() -> [CaptureDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let screens = NSScreen.screens
        return (0..<Int(count)).map { position in
            let id = ids[position]
            let bounds = CGDisplayBounds(id)
            let name = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }?.localizedName
            return CaptureDisplay(
                index: position + 1,
                name: name ?? (position == 0 ? "Main display" : "Display \(position + 1)"),
                width: Int(bounds.width),
                height: Int(bounds.height)
            )
        }
    }
}
