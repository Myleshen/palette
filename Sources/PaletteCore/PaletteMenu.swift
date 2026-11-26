import CoreGraphics
import Foundation

/// Shared geometry so the panel and its SwiftUI content agree on one width.
public enum PaletteMenuLayout {
    public static let width: CGFloat = 228
}

/// One row in a Palette-owned menu. The panel replaces SwiftUI's `Menu` and
/// `.contextMenu`, whose native `NSMenu` runs a tracking loop that swallows
/// Palette's global hotkeys until it closes.
///
/// This type is pure so the item rules and keyboard selection are testable
/// without opening a window.
public struct PaletteMenuItem: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case action
        case separator
        /// A non-selectable group title, e.g. a model endpoint in a long picker.
        case heading
    }

    public var id: String
    public var title: String
    /// Right-aligned hint such as "⌘1"; the caller owns the wording.
    public var shortcut: String?
    public var checked: Bool
    public var enabled: Bool
    public var role: Role

    public init(
        id: String,
        title: String,
        shortcut: String? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        role: Role = .action
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.checked = checked
        self.enabled = enabled
        self.role = role
    }

    public static func separator(_ id: String) -> PaletteMenuItem {
        PaletteMenuItem(id: id, title: "", enabled: false, role: .separator)
    }

    public static func heading(_ id: String, _ title: String) -> PaletteMenuItem {
        PaletteMenuItem(id: id, title: title, enabled: false, role: .heading)
    }

    /// Only a visible, enabled action can take the keyboard highlight or run.
    public var isSelectable: Bool {
        role == .action && enabled
    }
}

/// Highlight state and keyboard movement for a menu. The panel owns one of
/// these, and the tests pin the rules here rather than against AppKit.
public struct PaletteMenuSelection: Equatable, Sendable {
    public private(set) var items: [PaletteMenuItem]
    public private(set) var highlightedID: String?

    public init(items: [PaletteMenuItem], preferred: String? = nil) {
        self.items = items
        if let preferred,
           items.contains(where: { $0.id == preferred && $0.isSelectable }) {
            self.highlightedID = preferred
        } else {
            self.highlightedID = items.first(where: \.isSelectable)?.id
        }
    }

    public var selectableIDs: [String] {
        items.filter(\.isSelectable).map(\.id)
    }

    public var highlighted: PaletteMenuItem? {
        guard let highlightedID else { return nil }
        return items.first { $0.id == highlightedID && $0.isSelectable }
    }

    /// Hovering a disabled row must not move the keyboard selection off a row
    /// that can actually run.
    public mutating func highlight(_ id: String) {
        guard items.contains(where: { $0.id == id && $0.isSelectable }) else { return }
        highlightedID = id
    }

    /// Arrow movement skips separators and disabled rows and wraps at the ends.
    public mutating func move(_ delta: Int) {
        let ids = selectableIDs
        guard !ids.isEmpty else {
            highlightedID = nil
            return
        }
        guard let current = highlightedID,
              let index = ids.firstIndex(of: current) else {
            highlightedID = delta >= 0 ? ids.first : ids.last
            return
        }
        let count = ids.count
        let next = ((index + delta) % count + count) % count
        highlightedID = ids[next]
    }

    /// The row Return runs; nil for a separator, a disabled row or a dismissed
    /// menu, so Return can never fire something the user could not click.
    public var activation: PaletteMenuItem? {
        highlighted
    }

    /// The panel clears the highlight as it hides. A late Return on a closed
    /// menu then has nothing to run.
    public mutating func dismiss() {
        highlightedID = nil
    }
}
