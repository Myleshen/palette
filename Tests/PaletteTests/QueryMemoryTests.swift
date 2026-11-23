import XCTest
import PaletteCore

final class QueryMemoryTests: XCTestCase {
    func testDigestIsStableAndCaseInsensitive() {
        // Hardcoded so a change to the digest input is caught.
        XCTAssertEqual(
            QueryMemory.digest("chr"),
            "943723cd5955a5316f4364f750e309b0a9582e939128ce09800d56f126649efb"
        )
        XCTAssertEqual(QueryMemory.digest("chr"), QueryMemory.digest("chr"))

        let spaced = QueryMemory.learnablePrefix("  CHR  ")!
        XCTAssertEqual(QueryMemory.digest(spaced), QueryMemory.digest("chr"))
        XCTAssertNotEqual(QueryMemory.digest("chr"), QueryMemory.digest("chrom"))

        // Only the first 12 characters are digested.
        XCTAssertEqual(QueryMemory.digest("abcdefghijklm"), QueryMemory.digest("abcdefghijkl"))
        XCTAssertEqual(QueryMemory.digest("abc").count, 64)
    }

    func testLearnablePrefixLengthBounds() {
        XCTAssertNil(QueryMemory.learnablePrefix(""))
        XCTAssertNil(QueryMemory.learnablePrefix(" c "))
        XCTAssertEqual(QueryMemory.learnablePrefix("  Ch "), "ch")
        XCTAssertEqual(QueryMemory.learnablePrefix("abcdefghijkl"), "abcdefghijkl")
        XCTAssertNil(QueryMemory.learnablePrefix("abcdefghijklm"))
    }

    func testLearnedBoostIsCappedAndMonotonic() {
        XCTAssertEqual(Ranking.learnedBoost(count: 0), 0)
        let weak = Ranking.learnedBoost(count: 1)
        XCTAssertGreaterThan(weak, 0)
        XCTAssertLessThan(weak, Ranking.learnedBoost(count: 10))
        XCTAssertLessThanOrEqual(Ranking.learnedBoost(count: 10_000), 2.0)
    }

    func testLearnedBoostNeverBeatsABetterMatch() {
        // A prefix-band match with no history must stay above a much weaker
        // substring match that is learned at full strength.
        let strong = PaletteItem(id: "chrome", title: "Chrome", score: Ranking.score(query: "chr", candidate: "Chrome")!, providerID: "apps")
        let learned = PaletteItem(id: "x", title: "X", score: Ranking.score(query: "chr", candidate: "xchrx")!, providerID: "apps")
        let merged = Ranking.merge(
            [learned, strong],
            boosts: [learned.stableID: Ranking.learnedBoost(count: 10_000)]
        )
        XCTAssertEqual(merged.first?.stableID, strong.stableID)
    }

    func testLearnedBoostBreaksAScoreTie() {
        let first = PaletteItem(id: "a", title: "Alpha", score: 400, providerID: "apps")
        let second = PaletteItem(id: "b", title: "Beta", score: 400, providerID: "apps")
        let merged = Ranking.merge([first, second], boosts: [second.stableID: 2.0])
        XCTAssertEqual(merged.map(\.stableID), [second.stableID, first.stableID])
    }
}
