import XCTest
import PaletteCore

final class SearchRankingTests: XCTestCase {
    func testTierBandsRankBestToWorst() {
        let exact = Ranking.score(query: "kitty", candidate: "kitty")!
        let prefix = Ranking.score(query: "kit", candidate: "kitty")!
        let wordStart = Ranking.score(query: "kit", candidate: "litter kitten")!
        let substring = Ranking.score(query: "kit", candidate: "okita")!
        let subsequence = Ranking.score(query: "kit", candidate: "kangaroo island tent")!

        XCTAssertGreaterThan(exact, prefix, "exact must beat prefix")
        XCTAssertGreaterThan(prefix, wordStart, "prefix must beat word-start")
        XCTAssertGreaterThan(wordStart, substring, "word-start must beat substring")
        XCTAssertGreaterThan(substring, subsequence, "substring must beat subsequence")
        XCTAssertNil(Ranking.score(query: "kit", candidate: "safari"))
    }

    func testCaseAndDiacriticFoldingHappensBeforeScoring() {
        XCTAssertEqual(
            Ranking.score(query: "KITTY", candidate: "kitty"),
            Ranking.score(query: "kitty", candidate: "kitty")
        )
        XCTAssertEqual(
            Ranking.score(query: "cafe", candidate: "Café"),
            Ranking.score(query: "cafe", candidate: "cafe")
        )
    }

    func testConsecutiveRunsBeatScatteredMatchesWithinSubsequence() {
        let runs = Ranking.score(query: "abc", candidate: "xabxc")!
        let scattered = Ranking.score(query: "abc", candidate: "xaxbxc")!
        XCTAssertGreaterThan(runs, scattered)
    }

    func testEarlierFitWinsWithinAContiguousBand() {
        let early = Ranking.score(query: "kit", candidate: "okita")!
        let late = Ranking.score(query: "kit", candidate: "zzzzkit")!
        XCTAssertGreaterThan(early, late)
    }

    func testMergeKeepsTitleOrderForEqualScores() {
        let alpha = PaletteItem(id: "1", title: "Alpha", score: 100, providerID: "apps")
        let beta = PaletteItem(id: "2", title: "Beta", score: 100, providerID: "apps")
        XCTAssertEqual(Ranking.merge([beta, alpha]).map(\.title), ["Alpha", "Beta"])
    }
}
