import Foundation
import XCTest
@testable import PaletteProviders

final class GitHubTests: XCTestCase {
    func testKindTriggersAndNamesAreUnique() {
        let triggers = GitHubKind.allCases.map(\.trigger)
        XCTAssertEqual(triggers, ["gh", "ghr", "ghp", "ghi", "gha", "ghn"])
        XCTAssertEqual(Set(triggers).count, triggers.count)
        XCTAssertEqual(GitHubKind.context.id, "github")
        XCTAssertEqual(GitHubKind.actions.id, "gha")
        XCTAssertEqual(GitHubKind.notifications.id, "ghn")
        let names = GitHubKind.allCases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testRepoSlugMapsToCloneURL() {
        XCTAssertEqual(GitHubRepoRef.cloneURL(for: "Myleshen/palette"), "https://github.com/Myleshen/palette.git")
        XCTAssertEqual(GitHubRepoRef.name(from: "Myleshen/palette"), "palette")
        XCTAssertEqual(GitHubRepoRef.name(from: "palette"), "palette")
    }

    func testRemoteURLParsing() {
        XCTAssertEqual(GitHubRepoRef.slug(fromRemote: "git@github.com:Myleshen/palette.git"), "Myleshen/palette")
        XCTAssertEqual(GitHubRepoRef.slug(fromRemote: "https://github.com/Myleshen/palette.git"), "Myleshen/palette")
        XCTAssertEqual(GitHubRepoRef.slug(fromRemote: "https://github.com/Myleshen/palette"), "Myleshen/palette")
        XCTAssertNil(GitHubRepoRef.slug(fromRemote: ""))
        XCTAssertNil(GitHubRepoRef.slug(fromRemote: "palette"))
    }

    func testNotificationSubjectURLMapping() {
        XCTAssertEqual(
            GitHubNotification.webURL(
                subjectType: "Issue",
                subjectURL: "https://api.github.com/repos/Myleshen/palette/issues/42",
                repository: "Myleshen/palette"
            ),
            "https://github.com/Myleshen/palette/issues/42"
        )
        XCTAssertEqual(
            GitHubNotification.webURL(
                subjectType: "PullRequest",
                subjectURL: "https://api.github.com/repos/Myleshen/palette/pulls/7",
                repository: "Myleshen/palette"
            ),
            "https://github.com/Myleshen/palette/issues/7"
        )
        XCTAssertNil(GitHubNotification.webURL(subjectType: "Release", subjectURL: "https://api.github.com/repos/a/b/releases/1", repository: "a/b"))
        XCTAssertNil(GitHubNotification.webURL(subjectType: "Issue", subjectURL: nil, repository: "a/b"))
        XCTAssertNil(GitHubNotification.webURL(subjectType: "Issue", subjectURL: "https://api.github.com/repos/a/b/issues/1", repository: nil))
        XCTAssertNil(GitHubNotification.trailingNumber("https://api.github.com/repos/a/b/issues/"))
    }

    func testScopeErrorDetection() {
        XCTAssertTrue(GitHubNotification.isScopeError("HTTP 403: missing required scopes [notifications]"))
        XCTAssertTrue(GitHubNotification.isScopeError("This API operation needs the \"notifications\" scope."))
        XCTAssertFalse(GitHubNotification.isScopeError("dial tcp: lookup api.github.com"))
    }

    func testPaginatedNotificationsAreFlattened() throws {
        let data = Data(#"[[{"id":"1"},{"id":"2"}],[{"id":"3"}]]"#.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        XCTAssertEqual(GitHubProvider.flattenPages(parsed)?.count, 3)
        let single = try JSONSerialization.jsonObject(with: Data(#"[{"id":"1"}]"#.utf8))
        XCTAssertEqual(GitHubProvider.flattenPages(single)?.count, 1)
        XCTAssertNil(GitHubProvider.flattenPages([String: Any]()))
    }
}
