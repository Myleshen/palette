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
}
