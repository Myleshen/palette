import TOMLKit
import XCTest
import PaletteCore
import PalettePlatform

final class SettingsLogicTests: XCTestCase {
    func testInvalidEngineEditKeepsSavedCopy() {
        let saved = WebSearchEngine.defaults
        var drafts = saved
        drafts[0].urlTemplate = "https://broken.example/?q="

        // The broken Google row stays on screen, but the file keeps the last
        // valid Google; every other row is written as-is.
        XCTAssertEqual(WebSearchEngine.persisting(drafts, over: saved), saved)
    }

    func testDeletedEngineIsDropped() {
        let saved = WebSearchEngine.defaults
        let drafts = saved.filter { $0.name != "DuckDuckGo" }
        let persisted = WebSearchEngine.persisting(drafts, over: saved)

        XCTAssertEqual(persisted.map(\.name), ["Google", "GitHub", "YouTube"])
    }

    func testRenamedEngineReplacesItsSavedRow() {
        let saved = WebSearchEngine.defaults
        var drafts = saved
        drafts[0].name = "Google UK"

        let persisted = WebSearchEngine.persisting(drafts, over: saved)
        XCTAssertEqual(persisted.first?.name, "Google UK")
        XCTAssertEqual(persisted.count, saved.count)
    }

    func testDuplicateEngineNameAndBangAreFlagged() {
        let google = WebSearchEngine(name: "Google", urlTemplate: "https://a/?q={query}", keyword: "g")
        let other = WebSearchEngine(name: "Other", urlTemplate: "https://b/?q={query}", keyword: "o")

        let duplicateName = WebSearchEngine(
            name: " google ",
            urlTemplate: "https://c/?q={query}",
            keyword: "x"
        )
        XCTAssertEqual(
            duplicateName.validationIssue(among: [google, other, duplicateName]),
            "Another engine already uses this name."
        )

        let duplicateBang = WebSearchEngine(
            name: "Third",
            urlTemplate: "https://d/?q={query}",
            keyword: "G"
        )
        XCTAssertEqual(
            duplicateBang.validationIssue(among: [google, other, duplicateBang]),
            "Another engine already uses !G."
        )
        XCTAssertNil(other.validationIssue(among: [google, other]))
    }

    func testShortcutIdentityIgnoresModifierOrder() {
        let first = HotKeySpec.parse("opt+cmd+a")
        let second = HotKeySpec.parse("cmd+opt+a")

        XCTAssertEqual(first?.identity, second?.identity)
        XCTAssertEqual(Set([first?.identity, second?.identity]).count, 1)
    }

    func testDefaultTOMLGlobalProvidersMatchDefaults() throws {
        let table = try TOMLTable(string: ConfigLoader.defaultTOML())
        let listed = try XCTUnwrap(table.table("providers")?.strArray("global"))

        XCTAssertEqual(Set(listed), Set(PaletteConfig.defaultGlobalProviders))
        XCTAssertTrue(listed.contains("cheat"))
    }
}
