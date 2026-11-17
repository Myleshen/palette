import XCTest
@testable import PaletteCore
@testable import PaletteProviders

final class BangResolverTests: XCTestCase {
    private let engines = [
        WebSearchEngine(
            name: "AtWiki",
            urlTemplate: "https://w.atwiki.jp/?q={query}",
            keyword: "atwiki",
            browser: "Safari"
        ),
        WebSearchEngine(
            name: "DuckDuckGo",
            urlTemplate: "https://duckduckgo.com/?q={query}",
            keyword: "ddg"
        ),
        // No keyword: not bangable, even by name.
        WebSearchEngine(name: "Google", urlTemplate: "https://www.google.com/search?q={query}"),
    ]

    func testKeywordWithQuerySearchesInItsBrowser() {
        let items = BangResolver.items(for: "!atwiki swift ui", engines: engines)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Search AtWiki for “swift ui”")

        let action = items[0].actions.first
        XCTAssertEqual(action?.kind, .openURL)
        XCTAssertEqual(action?.value.object?["url"], "https://w.atwiki.jp/?q=swift%20ui")
        XCTAssertEqual(action?.value.object?["browser"], "Safari")
        XCTAssertNil(action?.value.object?["mode"])
    }

    func testBrowserIsAbsentWhenTheEngineUsesTheDefault() {
        let items = BangResolver.items(for: "!ddg palette", engines: engines)
        XCTAssertEqual(items.first?.actions.first?.value.object?["url"], "https://duckduckgo.com/?q=palette")
        XCTAssertNil(items.first?.actions.first?.value.object?["browser"])
    }

    func testEmptyQueryPromptsWithoutCrashing() {
        let items = BangResolver.items(for: "!atwiki", engines: engines)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].subtitle, "Type a query after !atwiki")
        XCTAssertEqual(items[0].actions.first?.value.object?["url"], "https://w.atwiki.jp/?q=")
    }

    func testNameMatchesWhenTheKeywordDoesNot() {
        XCTAssertEqual(BangResolver.items(for: "!DuckDuckGo", engines: engines).count, 1)
    }

    func testPartialTokenListsMatchingEngines() {
        let items = BangResolver.items(for: "!d", engines: engines)
        XCTAssertEqual(Set(items.map(\.title)), ["!ddg — DuckDuckGo"])
        XCTAssertTrue(items.allSatisfy { $0.badge == "BANG" })
    }

    func testBareBangListsEveryBangableEngine() {
        let items = BangResolver.items(for: "!", engines: engines)
        XCTAssertEqual(Set(items.map(\.title)), ["!atwiki — AtWiki", "!ddg — DuckDuckGo"])
    }

    func testNonBangQueryProducesNothing() {
        XCTAssertTrue(BangResolver.items(for: "atwiki", engines: engines).isEmpty)
    }
}
