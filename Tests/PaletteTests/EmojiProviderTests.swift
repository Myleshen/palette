import XCTest
@testable import PaletteCore
@testable import PaletteProviders

final class EmojiProviderTests: XCTestCase {
    func testEnterPastesEmojiAndCopyIsSecondary() async throws {
        let provider = EmojiProvider()
        let items = try await provider.search(SearchRequest(text: "fire", limit: 20, isBound: true))
        let item = try XCTUnwrap(items.first)

        let paste = try XCTUnwrap(item.actions.first)
        XCTAssertEqual(paste.kind, .pasteText)
        let glyph = try XCTUnwrap(paste.value.text)
        XCTAssertFalse(glyph.isEmpty)
        XCTAssertTrue(item.title.hasPrefix(glyph))

        let copy = try XCTUnwrap(item.actions.dropFirst().first)
        XCTAssertEqual(copy.kind, .copyText)
        XCTAssertEqual(copy.value.text, glyph)
    }

    func testEmptyQueryAlsoPastesFirst() async throws {
        let provider = EmojiProvider()
        let items = try await provider.search(SearchRequest(text: "", limit: 20, isBound: true))
        XCTAssertEqual(items.first?.actions.first?.kind, .pasteText)
    }
}
