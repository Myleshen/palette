import Foundation

/// What a card in the theme gallery applies. Wallpaper is the extracted
/// desktop palette, not a theme file, so it carries no theme id.
public enum ThemeCardTarget: Equatable, Sendable {
    case wallpaper
    case theme(String)
}

/// One card in the gallery. The catalogue's metadata is enough to draw a card,
/// so the deck never parses a TOML file while flipping.
public struct ThemeCard: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case wallpaper
        case theme(ThemeInfo)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static let wallpaper = ThemeCard(kind: .wallpaper)

    public static func theme(_ info: ThemeInfo) -> ThemeCard {
        ThemeCard(kind: .theme(info))
    }

    public var id: String {
        info?.name ?? "wallpaper"
    }

    /// Cache key for the parsed swatches. A user theme named "wallpaper" must
    /// not collide with the desktop card.
    public var cacheKey: String {
        info.map { "theme:\($0.name)" } ?? "wallpaper"
    }

    public var info: ThemeInfo? {
        guard case .theme(let info) = kind else { return nil }
        return info
    }

    public var themeID: String? { info?.name }

    public var target: ThemeCardTarget {
        info.map { .theme($0.name) } ?? .wallpaper
    }

    public var displayName: String { info?.displayName ?? "From wallpaper" }

    /// Empty for the wallpaper card until its extracted palette has loaded.
    public var appearance: String { info?.appearance ?? "" }

    public var sectionTitle: String { info?.section.title ?? "Wallpaper" }

    /// The live theme reports its display name; a `/theme` id or either name
    /// must find the same card.
    public func matches(_ name: String) -> Bool {
        guard let info else { return name.lowercased() == "wallpaper" }
        return info.name == name || info.displayName == name
    }
}

/// The ordered card list: wallpaper first, then the browser's sections
/// (Built-in, Ghostty, Omarchy, Custom). Movement wraps at both ends.
public struct ThemeCardDeck: Equatable, Sendable {
    public private(set) var cards: [ThemeCard]
    public var selected: Int

    public init(cards: [ThemeCard] = [.wallpaper], selected: Int = 0) {
        self.cards = cards.isEmpty ? [.wallpaper] : cards
        self.selected = min(max(0, selected), self.cards.count - 1)
    }

    public init(catalog: ThemeBrowserCatalog, currentTheme: String? = nil) {
        var cards: [ThemeCard] = [.wallpaper]
        for section in catalog.sections {
            cards.append(contentsOf: section.themes.map(ThemeCard.theme))
        }
        self.init(cards: cards)
        if let currentTheme, let index = cards.firstIndex(where: { $0.matches(currentTheme) }) {
            selected = index
        }
    }

    public var count: Int { cards.count }
    public var current: ThemeCard { cards[selected] }
    public var previous: ThemeCard { cards[wrapped(selected - 1)] }
    public var next: ThemeCard { cards[wrapped(selected + 1)] }

    public mutating func move(by delta: Int) {
        guard !cards.isEmpty else { return }
        selected = wrapped(selected + delta)
    }

    public mutating func jumpToFirst() { selected = 0 }

    public mutating func jumpToLast() { selected = cards.count - 1 }

    /// Display name → theme file id. The gallery and the live theme speak
    /// display names, while the apply paths want the file name.
    public func themeID(forDisplay display: String) -> String? {
        for card in cards {
            guard let info = card.info else { continue }
            if info.displayName == display || info.name == display {
                return info.name
            }
        }
        return nil
    }

    private func wrapped(_ index: Int) -> Int {
        let count = cards.count
        return ((index % count) + count) % count
    }
}

/// The four large blocks and the ANSI dots a card draws. Parsed off-main and
/// cached per card by the gallery.
public struct ThemeCardPalette: Equatable, Sendable {
    public var appearance: String
    public var background: String
    public var foreground: String
    public var accent: String
    public var selection: String
    /// Exactly 16 entries, ANSI 0...15.
    public var ansi: [String]

    public init(
        appearance: String,
        background: String,
        foreground: String,
        accent: String,
        selection: String,
        ansi: [String]
    ) {
        self.appearance = appearance
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.selection = selection
        self.ansi = ansi
    }

    public init(palette: PalettePalette) {
        self.init(
            appearance: palette.appearance,
            background: palette.background,
            foreground: palette.foreground,
            accent: palette.cursor,
            selection: palette.selectionBackground,
            ansi: palette.ansi
        )
    }

    public init(theme: Theme) {
        self.init(palette: PalettePalette(theme: theme))
    }

    /// The eight most luminous ANSI entries, kept in ANSI order so the dots
    /// line up with the terminal's numbering.
    public var brightestANSI: [String] {
        let ranked = ansi.enumerated().sorted {
            (RGBA(hex: $0.element)?.luminance ?? 0) > (RGBA(hex: $1.element)?.luminance ?? 0)
        }
        let keep = Set(ranked.prefix(8).map(\.offset))
        return ansi.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }
}
