import XCTest
@testable import PaletteProviders

final class GitHubTests: XCTestCase {
    func testKindTriggersAndNamesAreUnique() {
        let triggers = GitHubKind.allCases.map(\.trigger)
        XCTAssertEqual(triggers, ["gh", "ghr", "ghp", "ghi"])
        XCTAssertEqual(Set(triggers).count, triggers.count)
        XCTAssertEqual(GitHubKind.context.id, "github")
        let names = GitHubKind.allCases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testRepoSlugMapsToCloneURL() {
        XCTAssertEqual(GitHubRepoRef.cloneURL(for: "Myleshen/palette"), "https://github.com/Myleshen/palette.git")
        XCTAssertEqual(GitHubRepoRef.name(from: "Myleshen/palette"), "palette")
        XCTAssertEqual(GitHubRepoRef.name(from: "palette"), "palette")
    }
}
