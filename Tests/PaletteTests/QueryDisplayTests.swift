import XCTest
@testable import PaletteCore

final class QueryDisplayTests: XCTestCase {
    private let display = QueryDisplay(parser: QueryParser(prefix: "/", triggers: [
        TriggerEntry(trigger: "gh", providerID: "gh"),
        TriggerEntry(trigger: "ghp", providerID: "ghp"),
        TriggerEntry(trigger: "bw", providerID: "bw"),
        TriggerEntry(trigger: "bwu", providerID: "bwu"),
        TriggerEntry(trigger: "bwt", providerID: "bwt"),
        TriggerEntry(trigger: "bwn", providerID: "bwn"),
        TriggerEntry(trigger: "bwo", providerID: "bwo"),
        TriggerEntry(trigger: "rec", providerID: "rec"),
        TriggerEntry(trigger: "recent", providerID: "recent"),
        TriggerEntry(trigger: "shot", providerID: "shot"),
        TriggerEntry(trigger: "shots", providerID: "shots"),
        TriggerEntry(trigger: "ask", providerID: "ask"),
        TriggerEntry(trigger: "zj", providerID: "zj"),
    ]))

    // MARK: - Forward mapping

    func testBoundQueryWithTextHidesTheTrigger() {
        XCTAssertEqual(display.visible(for: "/gh foo"), "foo")
        XCTAssertEqual(display.visible(for: "/ghp src/App.swift"), "src/App.swift")
        XCTAssertEqual(display.visible(for: "/ask"), "")
    }

    func testResolvedTriggerWithSeparatorIsHiddenEvenWhenEmpty() {
        XCTAssertEqual(display.visible(for: "/gh "), "")
        XCTAssertEqual(display.visible(for: "/gh   "), "")
    }

    func testUniqueShortTriggerHidesImmediatelyEvenUnspaced() {
        XCTAssertEqual(display.visible(for: "/ask"), "")
        XCTAssertEqual(display.visible(for: "/zj"), "")
        XCTAssertEqual(display.visible(for: "/bwn"), "")
        XCTAssertEqual(display.visible(for: "/ghp"), "")
    }

    func testAmbiguousUnspacedTriggerShowsRawQuery() {
        // Both are proper prefixes of longer triggers, so hiding them would
        // turn the next keystroke into text and lose the longer trigger.
        XCTAssertEqual(display.visible(for: "/gh"), "/gh")
        XCTAssertEqual(display.visible(for: "/bw"), "/bw")
        XCTAssertEqual(display.visible(for: "/rec"), "/rec")
        XCTAssertEqual(display.visible(for: "/shot"), "/shot")
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

    func testTypingRawTokenRebuildsTheLongerTrigger() {
        XCTAssertEqual(display.query(forVisible: "/bwn", previous: "/bw"), "/bwn")
        XCTAssertEqual(display.query(forVisible: "/ghp", previous: "/gh"), "/ghp")
        XCTAssertEqual(display.query(forVisible: "/recent", previous: "/rec"), "/recent")
    }

    func testRoundTripKeepsTheQueryBound() {
        for internalQuery in ["/gh foo", "/ghp src/App.swift", "/ask hi", "/gh", "/bw"] {
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

    func testTypingBwnIsNotCapturedByBw() {
        var internalQuery = ""
        var visible = ""
        var atBw: (query: String, visible: String)?

        for character in "/bwn" {
            visible.append(character)
            internalQuery = display.query(forVisible: visible, previous: internalQuery)
            visible = display.visible(for: internalQuery)
            if internalQuery == "/bw" { atBw = (internalQuery, visible) }
        }

        // "/bw" is bound for results but stays on screen so typing can continue.
        XCTAssertEqual(atBw?.query, "/bw")
        XCTAssertEqual(atBw?.visible, "/bw")
        XCTAssertEqual(internalQuery, "/bwn")
        XCTAssertEqual(display.visible(for: internalQuery), "")

        // No lock: the next keystroke is search text for the bound provider.
        internalQuery = display.query(forVisible: "x", previous: internalQuery)
        XCTAssertEqual(internalQuery, "/bwn x")
        XCTAssertEqual(display.visible(for: internalQuery), "x")
    }

    func testTypingLongerTriggerUnspacedReachesIt() {
        var internalQuery = ""
        var visible = ""
        for character in "/recent" {
            visible.append(character)
            internalQuery = display.query(forVisible: visible, previous: internalQuery)
            visible = display.visible(for: internalQuery)
        }
        XCTAssertEqual(display.parser.parse(internalQuery).trigger, "recent")
        XCTAssertEqual(internalQuery, "/recent")
        XCTAssertEqual(visible, "")
    }

    func testTypingSeparatorHidesTheAmbiguousTrigger() {
        var internalQuery = "/gh"
        XCTAssertEqual(display.visible(for: internalQuery), "/gh")
        internalQuery = display.query(forVisible: "/gh ", previous: internalQuery)
        XCTAssertEqual(internalQuery, "/gh ")
        XCTAssertEqual(display.visible(for: internalQuery), "")
    }

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

    // MARK: - Parser

    func testLongestTriggerWinsForEveryPrefixPair() {
        let parser = display.parser
        for trigger in parser.triggers.map(\.trigger) {
            let parsed = parser.parse("/" + trigger)
            XCTAssertEqual(parsed.trigger, trigger)
            XCTAssertEqual(parsed.providerID, trigger)
            XCTAssertEqual(parsed.text, "")
        }

        for longer in parser.triggers.map(\.trigger) {
            for shorter in parser.triggers.map(\.trigger)
            where longer != shorter && longer.hasPrefix(shorter) {
                XCTAssertEqual(parser.parse("/" + longer).providerID, longer)
                XCTAssertEqual(parser.parse("/" + shorter).providerID, shorter)
            }
        }
    }

    func testAliasesResolveLikeTriggers() {
        let parser = QueryParser(prefix: "/", triggers: [
            TriggerEntry(trigger: "bw", providerID: "bw"),
            TriggerEntry(trigger: "bwn", providerID: "bwn"),
            TriggerEntry(trigger: "b", providerID: "bw"),
        ])
        XCTAssertEqual(parser.parse("/bwn").providerID, "bwn")
        XCTAssertEqual(parser.parse("/b").providerID, "bw")
        XCTAssertEqual(parser.parse("/bw").providerID, "bw")
        XCTAssertEqual(parser.parse("/bwn note").text, "note")
    }
}
