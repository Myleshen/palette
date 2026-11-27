import Foundation

/// What a card in the theme gallery applies. Wallpaper is the extracted
/// desktop palette, not a theme file, so it carries no theme id. A wallpaper
/// file card names the picture it wants on the desktop first.
public enum ThemeCardTarget: Equatable, Sendable {
    case wallpaper
    case wallpaperFile(String)
    case theme(String)
}

/// One card in the gallery. The catalogue's metadata is enough to draw a card,
/// so the deck never parses a TOML file while flipping.
public struct ThemeCard: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case wallpaper
        case wallpaperFile(URL)
        case theme(ThemeInfo)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static let wallpaper = ThemeCard(kind: .wallpaper)

    public static func wallpaperFile(_ url: URL) -> ThemeCard {
        ThemeCard(kind: .wallpaperFile(url.standardizedFileURL))
    }

    public static func theme(_ info: ThemeInfo) -> ThemeCard {
        ThemeCard(kind: .theme(info))
    }

    public var id: String {
        switch kind {
        case .wallpaper: return "wallpaper"
        case .wallpaperFile(let url): return "wallpaper-file:\(url.path)"
        case .theme(let info): return info.name
        }
    }

    /// Cache key for the parsed swatches. A user theme named "wallpaper" must
    /// not collide with the desktop card.
    public var cacheKey: String {
        switch kind {
        case .wallpaper: return "wallpaper"
        case .wallpaperFile(let url): return "wallpaper-file:\(url.path)"
        case .theme(let info): return "theme:\(info.name)"
        }
    }

    public var info: ThemeInfo? {
        guard case .theme(let info) = kind else { return nil }
        return info
    }

    public var themeID: String? { info?.name }

    /// The picture a wallpaper file card applies, nil for every other card.
    public var wallpaperPath: String? {
        guard case .wallpaperFile(let url) = kind else { return nil }
        return url.path
    }

    public var target: ThemeCardTarget {
        switch kind {
        case .wallpaper: return .wallpaper
        case .wallpaperFile(let url): return .wallpaperFile(url.path)
        case .theme(let info): return .theme(info.name)
        }
    }

    public var displayName: String {
        switch kind {
        case .wallpaper: return "From wallpaper"
        case .wallpaperFile(let url): return url.lastPathComponent
        case .theme(let info): return info.displayName
        }
    }

    /// Empty for the wallpaper card until its extracted palette has loaded.
    public var appearance: String { info?.appearance ?? "" }

    public var sectionTitle: String {
        switch kind {
        case .wallpaper: return "Wallpaper"
        case .wallpaperFile: return "Wallpapers"
        case .theme(let info): return info.section.title
        }
    }

    public var isWallpaper: Bool {
        if case .theme = kind { return false }
        return true
    }

    /// The live theme reports its display name; a `/theme` id or either name
    /// must find the same card.
    public func matches(_ name: String) -> Bool {
        guard let info else { return name.lowercased() == "wallpaper" }
        return info.name == name || info.displayName == name
    }

    /// Substring, case-insensitive, over what the card shows and the id the
    /// user may half-remember.
    public func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        var parts = [displayName, sectionTitle]
        if let info {
            parts.append(info.name)
            parts.append(info.canonicalName)
        }
        return parts.joined(separator: " ").lowercased().contains(needle)
    }
}

/// The deck's two shows: theme cards and wallpaper cards. A hotkey picks one;
/// filters and the favourites view then stay inside it.
public enum ThemeCardMode: String, Equatable, Sendable, CaseIterable {
    case colors
    case wallpapers

    public var title: String {
        switch self {
        case .colors: return "Colors"
        case .wallpapers: return "Wallpapers"
        }
    }

    public func includes(_ card: ThemeCard) -> Bool {
        switch self {
        case .colors: return !card.isWallpaper
        case .wallpapers: return card.isWallpaper
        }
    }
}

/// The ordered card list: wallpapers, then the browser's sections (Built-in,
/// Ghostty, Omarchy, Custom). `selected` indexes the visible list, so a filter
/// or the favourites view never has to remap it. Movement wraps at both ends.
public struct ThemeCardDeck: Equatable, Sendable {
    public private(set) var cards: [ThemeCard]
    public var selected: Int
    public var mode: ThemeCardMode = .colors {
        didSet {
            if mode != oldValue { selected = 0 }
        }
    }
    public var query: String = "" {
        didSet {
            if query != oldValue { selected = 0 }
        }
    }
    public var favouritesOnly = false {
        didSet {
            if favouritesOnly != oldValue { selected = 0 }
        }
    }
    /// Card cache keys, so a theme id and a wallpaper path can share the store.
    public var favourites: Set<String> = []
    /// Path of the picture currently on the desktop, for the dot on its card.
    public var currentDesktopPath: String?

    public init(cards: [ThemeCard] = [.wallpaper], selected: Int = 0, mode: ThemeCardMode = .colors) {
        self.cards = cards.isEmpty ? [.wallpaper] : cards
        self.mode = mode
        self.selected = min(max(0, selected), self.cards.count - 1)
    }

    /// Wallpaper files lead the deck. The "From wallpaper" card stays as the
    /// first entry when the folder is empty or the desktop picture is not one
    /// of its files, so the W behaviour is always reachable.
    public init(
        catalog: ThemeBrowserCatalog,
        currentTheme: String? = nil,
        wallpapers: [URL] = [],
        currentDesktop: URL? = nil,
        mode: ThemeCardMode = .colors
    ) {
        var cards: [ThemeCard] = []
        let files = wallpapers.map(ThemeCard.wallpaperFile)
        let desktopPath = currentDesktop?.standardizedFileURL.path
        let desktopIsListed = desktopPath.map { path in
            files.contains { $0.wallpaperPath == path }
        } ?? false
        if files.isEmpty || !desktopIsListed {
            cards.append(.wallpaper)
        }
        cards.append(contentsOf: files)
        for section in catalog.sections {
            cards.append(contentsOf: section.themes.map(ThemeCard.theme))
        }
        self.init(cards: cards, mode: mode)
        if mode == .colors, let currentTheme,
           let index = visible.firstIndex(where: { $0.matches(currentTheme) }) {
            selected = index
        }
    }

    /// The filtered hand the fan draws.
    public var visible: [ThemeCard] {
        cards.filter { card in
            guard mode.includes(card) else { return false }
            guard card.matches(query: query) else { return false }
            return !favouritesOnly || favourites.contains(card.cacheKey)
        }
    }

    public var count: Int { visible.count }
    public var current: ThemeCard {
        let list = visible
        guard !list.isEmpty else { return .wallpaper }
        return list[min(max(0, selected), list.count - 1)]
    }
    public var previous: ThemeCard {
        let list = visible
        guard !list.isEmpty else { return .wallpaper }
        return list[wrapped(clampedSelection - 1)]
    }
    public var next: ThemeCard {
        let list = visible
        guard !list.isEmpty else { return .wallpaper }
        return list[wrapped(clampedSelection + 1)]
    }

    public var isCurrentFavourite: Bool { favourites.contains(current.cacheKey) }

    public var isCurrentOnDesktop: Bool {
        guard let path = current.wallpaperPath else { return false }
        return path == currentDesktopPath
    }

    public mutating func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        selected = wrapped(clampedSelection + delta)
    }

    public mutating func jumpToFirst() { selected = 0 }

    public mutating func jumpToLast() { selected = max(0, visible.count - 1) }

    public mutating func toggleFavourite() {
        let key = current.cacheKey
        if favourites.contains(key) {
            favourites.remove(key)
        } else {
            favourites.insert(key)
        }
    }

    /// The cards the fan draws, wrapped so a hand always has neighbours at
    /// either end of the deck. Relative 0 is the selection.
    public func fanWindow(reach: Int) -> [FanSlot] {
        let list = visible
        guard !list.isEmpty, reach >= 0 else { return [] }
        if list.count <= reach * 2 + 1 {
            return list.enumerated().map { FanSlot(relative: $0.offset - clampedSelection, card: $0.element) }
        }
        return (-reach...reach).map { relative in
            FanSlot(relative: relative, card: list[wrapped(clampedSelection + relative)])
        }
    }

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

    private var clampedSelection: Int {
        let count = cards.count
        guard count > 0 else { return 0 }
        let shown = visible.count
        guard shown > 0 else { return 0 }
        return min(max(0, selected), shown - 1)
    }

    private func wrapped(_ index: Int) -> Int {
        let count = visible.count
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }
}

/// One card and its distance from the selection, as the fan draws it.
public struct FanSlot: Equatable, Sendable {
    public var relative: Int
    public var card: ThemeCard

    public init(relative: Int, card: ThemeCard) {
        self.relative = relative
        self.card = card
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
