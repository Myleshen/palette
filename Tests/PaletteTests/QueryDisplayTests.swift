import XCTest
@testable import PaletteCore

final class QueryDisplayTests: XCTestCase {
    private let display = QueryDisplay(parser: QueryParser(prefix: "/", triggers: [
        TriggerEntry(trigger: "gh", providerID: "gh"),
        TriggerEntry(trigger: "ghp", providerID: "ghp"),
        TriggerEntry(trigger: "ask", providerID: "ask"),
    ]))

    // MARK: - Forward mapping

    func testBoundQueryWithTextHidesTheTrigger() {
        XCTAssertEqual(display.visible(for: "/gh foo"), "foo")
        XCTAssertEqual(display.visible(for: "/ghp src/App.swift"), "src/App.swift")
        XCTAssertEqual(display.visible(for: "/ask"), "")
    }

    func testResolvedTriggerIsHiddenEvenWhenEmpty() {
        XCTAssertEqual(display.visible(for: "/gh "), "")
        XCTAssertEqual(display.visible(for: "/gh"), "")
        XCTAssertEqual(display.visible(for: "/gh   "), "")
    }

    func testPlainUnboundAndUnknownQueriesAreUnchanged() {
        XCTAssertEqual(display.visible(for: ""), "")
        XCTAssertEqual(display.visible(for: "foo bar"), "foo bar")
        XCTAssertEqual(display.visible(for: "/xy foo"), "/xy foo")
        XCTAssertEqual(display.visible(for: "/Users/me"), "/Users/me")
    }

    // MARK: - Inverse mapping

    func testTypingVisibleTextRebuildsTheSamePrefix() {
        XCTAssertEqual(display.query(forVisible: "foo", previous: "/gh "), "/gh foo")
        XCTAssertEqual(display.query(forVisible: "src/App.swift", previous: "/ghp "), "/ghp src/App.swift")
        XCTAssertEqual(display.query(forVisible: "hi", previous: "/ask"), "/ask hi")
    }

    func testRoundTripKeepsTheQueryBound() {
        for internalQuery in ["/gh foo", "/ghp src/App.swift", "/ask hi"] {
            let visible = display.visible(for: internalQuery)
            XCTAssertEqual(display.query(forVisible: visible, previous: internalQuery), internalQuery)
            XCTAssertEqual(display.visible(for: display.query(forVisible: visible, previous: internalQuery)), visible)
        }
    }

    func testUnboundEditsPassThrough() {
        XCTAssertEqual(display.query(forVisible: "atlas", previous: "atl"), "atlas")
        XCTAssertEqual(display.query(forVisible: "/xy", previous: ""), "/xy")
    }

    // MARK: - Field behaviour

    func testDeletingToEmptyKeepsTheProviderButHidesIt() {
        // Backspace on the empty field clears the binding in the controller;
        // the mapping itself keeps the provider while the field looks empty.
        var internalQuery = "/gh foo"
        for visible in ["fo", "f", ""] {
            internalQuery = display.query(forVisible: visible, previous: internalQuery)
        }
        XCTAssertEqual(internalQuery, "/gh ")
        XCTAssertEqual(display.visible(for: internalQuery), "")
    }

    func testTypingWhileThePrefixIsShownStripsItOnce() {
        XCTAssertEqual(display.query(forVisible: "/gh f", previous: "/gh "), "/gh f")
        XCTAssertEqual(display.visible(for: "/gh f"), "f")
    }

    func testMovingToAnotherProviderKeepsTheVisibleText() {
        let typed = display.visible(for: "/gh foo")
        let moved = display.query(forVisible: typed, previous: "/ghp foo")
        XCTAssertEqual(moved, "/ghp foo")
        XCTAssertEqual(display.visible(for: moved), typed)
    }

    func testPrefixDisappearsWithoutRewritingTheText() {
        // The visible string is exactly the typed text, so the caret keeps its
        // offset once the prefix drops off the front.
        let typed = "src/App.swift"
        let internalQuery = display.query(forVisible: typed, previous: "/gh ")
        XCTAssertEqual(display.visible(for: internalQuery), typed)
        XCTAssertEqual(display.visible(for: internalQuery).count, typed.count)
        XCTAssertEqual(display.visible(for: "/gh " + typed), typed)
    }
}
