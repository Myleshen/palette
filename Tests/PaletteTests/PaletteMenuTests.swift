import XCTest
@testable import PaletteCore

/// The menu panel reuses this pure selection model; the item rules and the
/// keyboard path are pinned here without opening a window.
final class PaletteMenuTests: XCTestCase {
    private let items: [PaletteMenuItem] = [
        PaletteMenuItem(id: "first", title: "First", shortcut: "⌘1"),
        .separator("gap"),
        PaletteMenuItem(id: "off", title: "Disabled", enabled: false),
        PaletteMenuItem(id: "checked", title: "Checked", checked: true),
        PaletteMenuItem(id: "last", title: "Last"),
    ]

    func testInitialHighlightSkipsSeparatorsAndDisabledRows() {
        let selection = PaletteMenuSelection(items: items)
        XCTAssertEqual(selection.highlightedID, "first")
        XCTAssertEqual(selection.selectableIDs, ["first", "checked", "last"])
        XCTAssertEqual(selection.activation?.id, "first")
    }

    func testMoveSkipsNonSelectableRowsAndWraps() {
        var selection = PaletteMenuSelection(items: items)
        selection.move(1)
        XCTAssertEqual(selection.highlightedID, "checked")
        selection.move(1)
        XCTAssertEqual(selection.highlightedID, "last")
        selection.move(1)
        XCTAssertEqual(selection.highlightedID, "first")
        selection.move(-1)
        XCTAssertEqual(selection.highlightedID, "last")
    }

    func testHoveringDisabledOrSeparatorKeepsTheSelection() {
        var selection = PaletteMenuSelection(items: items)
        selection.highlight("off")
        XCTAssertEqual(selection.highlightedID, "first")
        selection.highlight("gap")
        XCTAssertEqual(selection.highlightedID, "first")
    }

    func testPreferredHighlightStartsOnTheCheckedRow() {
        var selection = PaletteMenuSelection(items: items, preferred: "checked")
        XCTAssertEqual(selection.activation?.id, "checked")
        selection.highlight("off")
        XCTAssertEqual(selection.highlightedID, "checked")
    }

    func testDismissClearsTheHighlightSoReturnRunsNothing() {
        var selection = PaletteMenuSelection(items: items)
        XCTAssertNotNil(selection.activation)
        selection.dismiss()
        XCTAssertNil(selection.highlightedID)
        XCTAssertNil(selection.activation)
    }

    func testAllDisabledMenuHasNoHighlight() {
        var selection = PaletteMenuSelection(items: [
            .separator("gap"),
            PaletteMenuItem(id: "off", title: "Disabled", enabled: false),
        ])
        XCTAssertNil(selection.highlightedID)
        selection.move(1)
        XCTAssertNil(selection.highlightedID)
        XCTAssertNil(selection.activation)
    }

    func testItemKeepsShortcutAndCheckedState() {
        let item = PaletteMenuItem(id: "id", title: "Title", shortcut: "⌘K", checked: true)
        XCTAssertEqual(item.shortcut, "⌘K")
        XCTAssertTrue(item.checked)
        XCTAssertTrue(item.isSelectable)
        XCTAssertFalse(PaletteMenuItem.separator("s").isSelectable)
        XCTAssertFalse(PaletteMenuItem(id: "x", title: "X", enabled: false).isSelectable)
    }

    /// Mirrors `PaletteMenuPicker`: menu ids map back to values, the current
    /// value is the checkmarked row, and a disabled row cannot be chosen.
    func testPickerSelectionRoundTripsAndSkipsDisabledRows() {
        let values = ["png", "jpg", "gif"]
        var selected = "png"
        let items = [
            PaletteMenuItem(id: "choice:0", title: "PNG", checked: selected == values[0]),
            .heading("heading:png", "Images"),
            PaletteMenuItem(id: "choice:1", title: "JPG", checked: selected == values[1], enabled: false),
            PaletteMenuItem(id: "choice:2", title: "GIF", checked: false),
        ]
        var model = PaletteMenuSelection(items: items)

        XCTAssertEqual(model.activation?.id, "choice:0")
        model.move(1)
        XCTAssertEqual(model.activation?.id, "choice:2", "disabled row and heading are skipped")
        if let id = model.activation?.id, let index = Int(id.dropFirst("choice:".count)) {
            selected = values[index]
        }
        XCTAssertEqual(selected, "gif")
        model.highlight("choice:1")
        XCTAssertEqual(model.activation?.id, "choice:2", "a disabled row cannot take the highlight")
        XCTAssertFalse(PaletteMenuItem.heading("h", "Heading").isSelectable)
    }

    // MARK: - Search

    func testSearchAppearsOnlyAboveTheRowThreshold() {
        let short = (0..<PaletteMenuSearch.threshold).map {
            PaletteMenuItem(id: "row-\($0)", title: "Row \($0)")
        }
        XCTAssertFalse(PaletteMenuSearch.isSearchable(short))
        XCTAssertTrue(PaletteMenuSearch.isSearchable(short + [PaletteMenuItem(id: "extra", title: "Extra")]))
    }

    func testFilterMatchesCaseInsensitiveSubstringsAndKeepsEmptyQuery() {
        let items = [
            PaletteMenuItem(id: "solarized", title: "Solarized Dark"),
            PaletteMenuItem(id: "nord", title: "Nord"),
        ]
        XCTAssertEqual(PaletteMenuSearch.filtered(items, query: "SOLAR").map(\.id), ["solarized"])
        XCTAssertEqual(PaletteMenuSearch.filtered(items, query: "dark").map(\.id), ["solarized"])
        XCTAssertEqual(PaletteMenuSearch.filtered(items, query: "  ").map(\.id), ["solarized", "nord"])
        XCTAssertEqual(PaletteMenuSearch.filtered(items, query: "zzz").count, 0)
    }

    func testFilterDropsOrphanHeadingsAndSeparators() {
        let items: [PaletteMenuItem] = [
            .heading("h1", "OpenAI"),
            PaletteMenuItem(id: "gpt", title: "GPT-5"),
            .separator("gap"),
            PaletteMenuItem(id: "mini", title: "GPT-5 mini"),
            .heading("h2", "Anthropic"),
            PaletteMenuItem(id: "claude", title: "Claude Sonnet"),
        ]
        let filtered = PaletteMenuSearch.filtered(items, query: "gpt")
        XCTAssertEqual(filtered.map(\.id), ["h1", "gpt", "mini"])
        XCTAssertEqual(filtered.map(\.role), [.heading, .action, .action])

        let claude = PaletteMenuSearch.filtered(items, query: "anthropic")
        XCTAssertTrue(claude.isEmpty, "a heading alone is not a match")
    }

    func testFilteredSelectionStartsAtFirstMatchAndNavigatesMatches() {
        let items = (1...50).map {
            PaletteMenuItem(id: "row-\($0)", title: "Theme \($0)")
        }
        let filtered = PaletteMenuSearch.filtered(items, query: "theme 4")
        XCTAssertEqual(filtered.count, 11, "4 and 40...49")

        var selection = PaletteMenuSelection(items: filtered)
        XCTAssertEqual(selection.highlightedID, "row-4")
        selection.move(1)
        XCTAssertEqual(selection.highlightedID, "row-40")
        selection.move(1)
        XCTAssertEqual(selection.highlightedID, "row-41")
        selection.move(-1)
        XCTAssertEqual(selection.highlightedID, "row-40")
        selection.move(-1)
        XCTAssertEqual(selection.highlightedID, "row-4", "wraps inside the filtered rows")
        selection.move(-1)
        XCTAssertEqual(selection.highlightedID, "row-49", "wraps back to the last match")
    }

    func testFilteringKeepsAHighlightThatSurvivedAndFallsBackOtherwise() {
        let items = [
            PaletteMenuItem(id: "dark", title: "Theme Dark"),
            PaletteMenuItem(id: "light", title: "Theme Light"),
        ]
        let kept = PaletteMenuSelection(items: PaletteMenuSearch.filtered(items, query: "theme"), preferred: "light")
        XCTAssertEqual(kept.highlightedID, "light")
        let dropped = PaletteMenuSelection(items: PaletteMenuSearch.filtered(items, query: "dark"), preferred: "light")
        XCTAssertEqual(dropped.highlightedID, "dark")
    }

    func testContentHeightUsesFixedRowsSo942ThemesCanOpenWithoutMeasuring() {
        let items = (1...942).map { PaletteMenuItem(id: "row-\($0)", title: "Theme \($0)") }
        let expected = 942 * PaletteMenuMetrics.rowHeight
            + PaletteMenuMetrics.verticalPadding
            + PaletteMenuMetrics.searchBarHeight
        XCTAssertEqual(PaletteMenuMetrics.contentHeight(of: items, searchable: true), expected)
    }
}
