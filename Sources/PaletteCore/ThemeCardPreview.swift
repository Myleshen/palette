import Foundation

/// What the focused preview draws. A theme card shows its palette and a live
/// launcher mock; a wallpaper card shows the picture with its dots on top.
public enum ThemeCardPreviewContent: Equatable, Sendable {
    case palette
    case picture

    public init(card: ThemeCard) {
        self = card.isWallpaper ? .picture : .palette
    }
}

/// A key the deck understands, before modifiers are applied. Arrow and Return
/// key codes live here so the routing is testable without AppKit.
public enum ThemeCardCommand: Equatable, Sendable {
    case closeDeck
    case closePreview
    case openPreview
    case apply
    case flip(Int)
    case toggleFavouritesView
    case toggleFavourite
    case jumpFirst
    case jumpLast
    case deleteFilterCharacter
    case appendFilter(String)
}

public enum ThemeCardKeyRoute {
    private enum KeyCode {
        static let p: UInt16 = 35
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let tab: UInt16 = 48
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let home: UInt16 = 115
        static let end: UInt16 = 119
        static let backspace: UInt16 = 51
    }

    /// Preview first: Esc and P/Space collapse the preview, then a second Esc
    /// closes the deck. While a filter is being typed `p` is a letter, so the
    /// preview toggle there is Space (and P once the filter is cleared).
    public static func command(
        keyCode: UInt16,
        characters: String?,
        filterEmpty: Bool,
        previewing: Bool
    ) -> ThemeCardCommand? {
        switch keyCode {
        case KeyCode.escape:
            return previewing ? .closePreview : .closeDeck
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return .apply
        case KeyCode.space:
            return previewing ? .closePreview : .openPreview
        case KeyCode.p where filterEmpty:
            return previewing ? .closePreview : .openPreview
        case KeyCode.tab:
            return .toggleFavouritesView
        case KeyCode.left:
            return .flip(-1)
        case KeyCode.right:
            return .flip(1)
        case KeyCode.home:
            return .jumpFirst
        case KeyCode.end:
            return .jumpLast
        case KeyCode.backspace:
            return .deleteFilterCharacter
        default:
            break
        }
        guard let characters, !characters.isEmpty else { return nil }
        return .appendFilter(characters)
    }
}

/// The preview's grow-from-the-card animation. Reduce Motion swaps instantly.
public enum ThemeCardPreviewMotion {
    public static let startScale: Double = 0.3

    public static func visual(
        progress: Double,
        reduceMotion: Bool
    ) -> (scale: Double, opacity: Double) {
        guard !reduceMotion else { return (1, 1) }
        let value = min(max(progress, 0), 1)
        return (startScale + (1 - startScale) * value, value)
    }
}
