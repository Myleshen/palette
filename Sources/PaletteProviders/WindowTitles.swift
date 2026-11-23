import ApplicationServices
import CoreGraphics
import Foundation

/// A window title from the Accessibility layer, with the frame it occupies.
struct TitledWindow: Equatable, Sendable {
    let frame: CGRect
    let title: String
}

/// The Accessibility window list for one app. Mocked in tests so the window
/// switcher never needs a real app or an Accessibility grant.
protocol WindowTitleSource: Sendable {
    func titledWindows(for pid: pid_t) -> [TitledWindow]
}

/// Reads titles from `AXUIElement`. Only the app itself may need the grant;
/// without it every call returns an empty list.
struct AXWindowTitleSource: WindowTitleSource {
    func titledWindows(for pid: pid_t) -> [TitledWindow] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = AXAccess.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            guard let title = AXAccess.attribute(window, kAXTitleAttribute) as? String, !title.isEmpty,
                  let frame = Self.frame(of: window) else { return nil }
            return TitledWindow(frame: frame, title: title)
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = AXAccess.attribute(window, kAXPositionAttribute),
              let size = AXAccess.attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}

/// Fills the gaps left by a missing Screen Recording grant: when a CG window
/// has no name, look the owning app's AX windows up by frame. One snapshot per
/// app is kept for a few seconds, so a search asks each app at most once.
actor WindowTitleResolver {
    private let source: WindowTitleSource
    private let isTrusted: @Sendable () -> Bool
    private let ttl: TimeInterval
    private var cache: [pid_t: (at: Date, windows: [TitledWindow])] = [:]

    init(
        source: WindowTitleSource = AXWindowTitleSource(),
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        ttl: TimeInterval = 5
    ) {
        self.source = source
        self.isTrusted = isTrusted
        self.ttl = ttl
    }

    func title(for frame: CGRect, pid: pid_t) -> String? {
        guard isTrusted() else { return nil }
        let windows: [TitledWindow]
        if let cached = cache[pid], Date().timeIntervalSince(cached.at) < ttl {
            windows = cached.windows
        } else {
            windows = source.titledWindows(for: pid)
            cache[pid] = (Date(), windows)
        }
        return Self.match(frame: frame, in: windows)
    }

    /// The title of the window sitting in the same frame, within 2 pt.
    static func match(frame: CGRect, in windows: [TitledWindow]) -> String? {
        windows.first { candidate in
            !candidate.title.isEmpty
                && abs(candidate.frame.minX - frame.minX) <= 2
                && abs(candidate.frame.minY - frame.minY) <= 2
                && abs(candidate.frame.width - frame.width) <= 2
                && abs(candidate.frame.height - frame.height) <= 2
        }?.title
    }
}

enum AXAccess {
    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return result == .success ? value : nil
    }
}
