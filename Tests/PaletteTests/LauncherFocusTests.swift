import XCTest
@testable import PaletteCore

final class LauncherFocusTests: XCTestCase {
    func testTabWalksSearchListRailAndWraps() {
        XCTAssertEqual(LauncherFocus.tab(from: .search, forward: true, hasStrip: false), .list)
        XCTAssertEqual(LauncherFocus.tab(from: .list, forward: true, hasStrip: false), .rail)
        XCTAssertEqual(LauncherFocus.tab(from: .rail, forward: true, hasStrip: false), .search)
    }

    func testTabIncludesTheStripOnlyForAGroup() {
        XCTAssertEqual(LauncherFocus.tab(from: .rail, forward: true, hasStrip: true), .strip)
        XCTAssertEqual(LauncherFocus.tab(from: .strip, forward: true, hasStrip: true), .search)
    }

    func testShiftTabIsTheSameOrderReversed() {
        XCTAssertEqual(LauncherFocus.tab(from: .search, forward: false, hasStrip: false), .rail)
        XCTAssertEqual(LauncherFocus.tab(from: .rail, forward: false, hasStrip: false), .list)
        XCTAssertEqual(LauncherFocus.tab(from: .list, forward: false, hasStrip: false), .search)
        XCTAssertEqual(LauncherFocus.tab(from: .search, forward: false, hasStrip: true), .strip)
        XCTAssertEqual(LauncherFocus.tab(from: .strip, forward: false, hasStrip: true), .rail)
    }

    func testScratchpadHotkeyTargetsTheListQuery() {
        XCTAssertEqual(HotkeyTargets.scratchpadListQuery(prefix: "/"), "/scratch ")
        XCTAssertEqual(HotkeyTargets.scratchpadListQuery(prefix: ":"), ":scratch ")
        XCTAssertEqual(HotkeyTargets.scratchpadListTrigger, "scratch")
    }

    func testSecondScratchpadPressHidesAnOpenList() {
        XCTAssertEqual(
            HotkeyTargets.scratchpadAction(panelVisible: true, listActive: true),
            .hide
        )
        XCTAssertEqual(
            HotkeyTargets.scratchpadAction(panelVisible: true, listActive: false),
            .showList
        )
        XCTAssertEqual(
            HotkeyTargets.scratchpadAction(panelVisible: false, listActive: false),
            .showList
        )
    }
}
