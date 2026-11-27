import Foundation

/// Where a theme comes from. The order is the order the browser shows them.
public enum ThemeSection: String, CaseIterable, Identifiable, Sendable {
    case builtIn = "Built-in"
    case ghostty = "Ghostty"
    case omarchy = "Omarchy"
    case custom = "Custom"

    public var id: String { rawValue }
    public var title: String { rawValue }

    /// File-name prefix bundled ports use, so a section can be recognised
    /// without listing each port in the browser.
    var sourcePrefix: String? {
        switch self {
        case .ghostty: return "ghostty-"
        case .omarchy: return "omarchy-"
        case .builtIn, .custom: return nil
        }
    }
}

public extension ThemeInfo {
    /// User files win over bundled files in the catalogue, so `isBuiltin`
    /// already tells a user override from a shipped theme.
    var section: ThemeSection {
        guard isBuiltin else { return .custom }
        for section in [ThemeSection.omarchy, .ghostty] {
            if let prefix = section.sourcePrefix, name.hasPrefix(prefix) {
                return section
            }
        }
        return .builtIn
    }

    /// `ghostty-catppuccin-mocha` → `catppuccin-mocha`, so typing the scheme
    /// name without the source prefix still finds it.
    var canonicalName: String {
        guard let prefix = section.sourcePrefix, name.hasPrefix(prefix) else { return name }
        return String(name.dropFirst(prefix.count))
    }

    /// `Ghostty · Dracula` → `Dracula`; other names are unchanged.
    var shortDisplayName: String {
        let prefix = "\(section.title) · "
        return displayName.hasPrefix(prefix)
            ? String(displayName.dropFirst(prefix.count))
            : displayName
    }
}

public struct ThemeBrowserSection: Identifiable, Equatable, Sendable {
    public var section: ThemeSection
    public var themes: [ThemeInfo]

    public var id: String { section.id }
    public var title: String { section.title }
    public var count: Int { themes.count }

    public init(section: ThemeSection, themes: [ThemeInfo]) {
        self.section = section
        self.themes = themes
    }
}

/// The whole catalogue grouped once, with the lowercase haystack needed by the
/// search field precomputed so typing only walks strings.
public struct ThemeBrowserCatalog: Equatable, Sendable {
    public let sections: [ThemeBrowserSection]
    private let searchTexts: [String: String]

    public init(themes: [ThemeInfo]) {
        var grouped: [ThemeSection: [ThemeInfo]] = [:]
        var searchTexts: [String: String] = [:]
        for theme in themes {
            grouped[theme.section, default: []].append(theme)
            searchTexts[theme.name] = [theme.displayName, theme.shortDisplayName, theme.name, theme.canonicalName]
                .joined(separator: " ")
                .lowercased()
        }
        self.sections = ThemeSection.allCases.map {
            ThemeBrowserSection(section: $0, themes: grouped[$0] ?? [])
        }
        self.searchTexts = searchTexts
    }

    public var allThemes: [ThemeInfo] {
        sections.flatMap(\.themes)
    }

    public var count: Int { allThemes.count }

    public func info(named name: String) -> ThemeInfo? {
        allThemes.first { $0.name == name }
    }

    /// A display name resolves too, because the live theme reports its display
    /// name and a `/theme` override may not be in the configured slot.
    public func info(matching current: String) -> ThemeInfo? {
        allThemes.first { $0.name == current || $0.displayName == current }
    }

    /// Sections that still have a match. Empty sections disappear while
    /// searching; with an empty query every section is shown with its count.
    public func filtered(_ query: String) -> [ThemeBrowserSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.themes.filter {
                searchTexts[$0.name]?.contains(needle) == true
            }
            return matches.isEmpty ? nil : ThemeBrowserSection(section: section.section, themes: matches)
        }
    }
}

/// A small LRU of fully parsed themes for the browser's rows. Reading it never
/// touches disk, so a row body can ask for swatches without a parse; misses are
/// filled from a background load.
public struct ThemeSwatchCache: Sendable {
    public private(set) var themes: [String: Theme] = [:]
    private var order: [String] = []
    public let limit: Int

    public init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    public func theme(named name: String) -> Theme? {
        themes[name]
    }

    public mutating func store(_ theme: Theme, named name: String) {
        themes[name] = theme
        order.removeAll { $0 == name }
        order.append(name)
        while order.count > limit {
            themes[order.removeFirst()] = nil
        }
    }
}

/// Selection and preview state for the theme browser. It never touches the
/// configured theme; `applying(to:)` returns a new selection for the caller to
/// commit, which is what keeps clicking rows side-effect free.
public struct ThemeBrowserSession: Equatable, Sendable {
    public let catalog: ThemeBrowserCatalog
    public var query: String
    public private(set) var selected: String?
    public private(set) var applied: String?

    public init(catalog: ThemeBrowserCatalog, selected: String? = nil) {
        self.catalog = catalog
        self.query = ""
        self.selected = selected ?? catalog.allThemes.first?.name
    }

    public var sections: [ThemeBrowserSection] { catalog.filtered(query) }
    public var visibleThemes: [ThemeInfo] { sections.flatMap(\.themes) }
    public var selectedInfo: ThemeInfo? { selected.flatMap { catalog.info(named: $0) } }

    public mutating func select(_ name: String) {
        selected = name
        applied = nil
    }

    /// Arrow-key movement over the rows the search currently shows.
    public mutating func moveSelection(by delta: Int) {
        let themes = visibleThemes
        guard !themes.isEmpty else { return }
        let index = themes.firstIndex { $0.name == selected }
        let next = index.map { min(max(0, $0 + delta), themes.count - 1) }
            ?? (delta < 0 ? themes.count - 1 : 0)
        select(themes[next].name)
    }

    /// Writes the previewed theme into the slot that is on screen. The mode is
    /// kept, so Auto still follows the system appearance.
    public func applying(to selection: ThemeSelection, activeAppearance: String) -> ThemeSelection {
        guard let selected else { return selection }
        var updated = selection
        switch selection.mode {
        case .dark:
            updated.dark = selected
        case .light:
            updated.light = selected
        case .auto:
            if activeAppearance.lowercased() == "light" {
                updated.light = selected
            } else {
                updated.dark = selected
            }
        }
        return updated
    }

    public mutating func markApplied() {
        applied = selected
    }

    /// Puts the preview back on the theme that is actually on screen.
    public mutating func revert(to current: String) {
        if let info = catalog.info(matching: current) {
            selected = info.name
        }
        applied = nil
    }
}
