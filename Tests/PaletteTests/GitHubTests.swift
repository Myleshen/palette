import Foundation
import XCTest
import PaletteCore
import PalettePlatform
@testable import PaletteProviders

private actor GitHubTestBridge: HostBridge {
    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }
    func notify(_ message: String) async {}
    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startDates: [Date] = []
    private var endDates: [Date] = []

    func start() {
        lock.lock()
        startDates.append(Date())
        lock.unlock()
    }

    func end() {
        lock.lock()
        endDates.append(Date())
        lock.unlock()
    }

    var starts: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return startDates
    }

    var ends: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return endDates
    }
}

final class GitHubTests: XCTestCase {
    private static let prJSON = #"[{"number":1,"title":"PR one","state":"OPEN","isDraft":false,"url":"https://github.com/o/r/pull/1"}]"#
    private static let issueJSON = #"[{"number":2,"title":"Issue two","state":"OPEN","url":"https://github.com/o/r/issues/2"}]"#

    func testRepositoryPullsAndIssuesOverlap() async throws {
        let log = CallLog()
        let provider = GitHubProvider(
            kind: .context,
            launcher: await MainActor.run { LauncherService() },
            bridge: GitHubTestBridge(),
            run: { args, _, _ in
                log.start()
                try await Task.sleep(for: .milliseconds(200))
                log.end()
                let output = args.contains("pr") ? Self.prJSON : Self.issueJSON
                return ProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
            }
        )

        let items = try await provider.search(SearchRequest(text: "o/r", limit: 20, isBound: true))

        XCTAssertEqual(items.map(\.id), ["pr:1", "issue:2"])
        let starts = log.starts.sorted()
        let ends = log.ends.sorted()
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(ends.count, 2)
        // The second call starts before the first one finishes.
        XCTAssertLessThan(starts[1], ends[0])
    }

    func testFailedIssueCallStillReturnsPullRequests() async throws {
        let provider = GitHubProvider(
            kind: .context,
            launcher: await MainActor.run { LauncherService() },
            bridge: GitHubTestBridge(),
            run: { args, _, _ in
                if args.contains("issue") {
                    return ProcessResult(status: 1, stdout: Data(), stderr: Data("boom\n".utf8))
                }
                return ProcessResult(status: 0, stdout: Data(Self.prJSON.utf8), stderr: Data())
            }
        )

        let items = try await provider.search(SearchRequest(text: "o/r", limit: 20, isBound: true))

        XCTAssertEqual(items.map(\.id), ["pr:1"])
    }
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
