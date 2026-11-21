import XCTest
@testable import PaletteProviders

final class ProjectTests: XCTestCase {
    func testGitHubRepoSlug() {
        XCTAssertEqual(GitHubRepoRef.slug(from: "Myleshen/palette"), "Myleshen/palette")
        XCTAssertEqual(GitHubRepoRef.slug(from: "  owner_1/repo.js-2  "), "owner_1/repo.js-2")
        XCTAssertNil(GitHubRepoRef.slug(from: ""))
        XCTAssertNil(GitHubRepoRef.slug(from: "palette"))
        XCTAssertNil(GitHubRepoRef.slug(from: "https://github.com/owner/repo"))
        XCTAssertNil(GitHubRepoRef.slug(from: "owner/repo/extra"))
        XCTAssertNil(GitHubRepoRef.slug(from: "owner /repo"))
    }

    func testDevxRootParsing() {
        let toml = """
        projects = []
        managed_files = []

        [[roots]]
        name = "dev"
        path = "/Users/me/dev"

        [usage]
        pins = 0

        [[roots]]
        name = 'learning'
        path = "~/learning"
        """

        let roots = DevxConfig.roots(from: toml)
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots[0], DevxConfig.Root(name: "dev", path: "/Users/me/dev"))
        XCTAssertEqual(roots[1], DevxConfig.Root(name: "learning", path: "~/learning"))
    }

    func testDevxRootParsingSkipsIncompleteBlocks() {
        let toml = """
        [[roots]]
        name = "dev"

        [[roots]]
        path = "/tmp/dev"

        [[roots]]
        name = "only"
        path = "/tmp/only"
        """
        XCTAssertEqual(DevxConfig.roots(from: toml), [DevxConfig.Root(name: "only", path: "/tmp/only")])
        XCTAssertEqual(DevxConfig.roots(from: ""), [])
    }

    func testGitStateParsing() {
        let output = """
        B
        providers-pass
        C
        d179dc4 Merge gh fixes (2 hours ago)
        W
        /Users/me/dev/palette
        /Users/me/dev/.worktrees/palette/providers-pass
        N
        12
        """
        let state = ProjectProvider.parseGitState(output)
        XCTAssertEqual(state?.branch, "providers-pass")
        XCTAssertEqual(state?.lastCommit, "d179dc4 Merge gh fixes (2 hours ago)")
        XCTAssertEqual(state?.worktrees, ["palette", "providers-pass"])
        XCTAssertEqual(state?.changes, 12)
        XCTAssertTrue(state?.preview.contains("Worktrees palette, providers-pass") == true)
        XCTAssertNil(ProjectProvider.parseGitState("not a repository\n"))
    }

    func testHexColourParsing() {
        XCTAssertEqual(ColorProvider.parseHex("#5b7cfa"), "#5B7CFA")
        XCTAssertEqual(ColorProvider.parseHex(" 5B7CFA "), "#5B7CFA")
        XCTAssertNil(ColorProvider.parseHex("#fff"))
        XCTAssertNil(ColorProvider.parseHex("blue"))
        XCTAssertNil(ColorProvider.parseHex("#gggggg"))
    }

    func testProjectNameValidation() {
        XCTAssertEqual(ProjectName.validate("  my-new-project "), "my-new-project")
        XCTAssertNil(ProjectName.validate(""))
        XCTAssertNil(ProjectName.validate("   "))
        XCTAssertNil(ProjectName.validate("nested/name"))
        XCTAssertNil(ProjectName.validate(".."))
        XCTAssertNil(ProjectName.validate("a..b"))
    }
}
