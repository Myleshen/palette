import AppKit
import SwiftUI
import XCTest
@testable import PaletteApp
@testable import PaletteCore

/// The menu is a SwiftUI view in the app target, so this hosts it and counts
/// how many rows SwiftUI actually builds. A 942-row picker must not build 942
/// rows to show one page.
@MainActor
final class PaletteMenuLazinessTests: XCTestCase {
    func testLazyStackBuildsOnlyTheVisiblePage() {
        _ = NSApplication.shared
        let items = (1...942).map { PaletteMenuItem(id: "row-\($0)", title: "Theme \($0)") }
        let model = PaletteMenuModel()
        model.present(items: items, preferred: "row-471")

        var built: [String] = []
        let host = NSHostingView(rootView: PaletteMenuView(
            model: model,
            theme: Theme(),
            select: { _ in },
            onCommand: { _ in true },
            onQuery: { _ in },
            onRowBuilt: { built.append($0) }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PaletteMenuLayout.width, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: PaletteMenuLayout.width, height: 400)

        // Layout alone is enough; the window never has to be on screen.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertGreaterThan(built.count, 0, "the visible page still builds")
        XCTAssertLessThan(
            built.count,
            942 / 4,
            "a 942-row menu builds only a window of rows, not the whole list"
        )
        window.close()
    }

    /// Highlight changes touch one row's box, not the other 941.
    func testHighlightBoxesOnlyTrackRowsThatWereBuilt() {
        let items = (1...942).map { PaletteMenuItem(id: "row-\($0)", title: "Theme \($0)") }
        let model = PaletteMenuModel()
        model.present(items: items, preferred: nil)

        model.highlight("row-2")
        model.move(1)
        model.move(-1)

        XCTAssertEqual(model.activation?.id, "row-2")
        XCTAssertTrue(model.highlights.box("row-2").isOn)
    }

    /// The window starts just above the anchor and grows upward on demand, so
    /// opening never builds the 440 rows above a checked theme.
    func testRowWindowStartsAboveTheAnchorAndGrowsUpward() {
        let items = (1...942).map { PaletteMenuItem(id: "row-\($0)", title: "Theme \($0)") }
        let model = PaletteMenuModel()
        model.present(items: items, preferred: "row-471")

        XCTAssertEqual(model.windowStart, 440)
        XCTAssertEqual(model.items.count, 942)

        model.ensureRowsAbove(offset: 0)
        XCTAssertEqual(model.windowStart, 0, "scrolling into the spacer prepends every block")

        model.setQuery("Theme 42")
        XCTAssertEqual(model.windowStart, 0, "a filtered list starts at its first match")
        XCTAssertEqual(model.items.count, 11)
    }

    func testAnchorOffsetIsArithmeticOnFixedRowHeights() {
        let items = (1...942).map { PaletteMenuItem(id: "row-\($0)", title: "Theme \($0)") }
        XCTAssertEqual(
            PaletteMenuMetrics.anchorOffset(of: items, anchor: "row-471"),
            470 * PaletteMenuMetrics.rowHeight + PaletteMenuMetrics.rowHeight / 2
        )
        XCTAssertNil(PaletteMenuMetrics.anchorOffset(of: items, anchor: "missing"))
    }
}
