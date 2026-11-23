import XCTest
import TOMLKit
@testable import PaletteCore

final class UpdateTests: XCTestCase {
    func testSemanticVersionOrdersReleases() throws {
        let current = try XCTUnwrap(SemanticVersion("2.18.0"))
        let next = try XCTUnwrap(SemanticVersion("2.18.1"))
        let later = try XCTUnwrap(SemanticVersion("2.19.0"))
        XCTAssertLessThan(current, next)
        XCTAssertLessThan(next, later)
        XCTAssertEqual(current, SemanticVersion("2.18.0"))
        XCTAssertFalse(UpdatePolicy.isNewer("2.18.0", than: "2.18.0"))
        XCTAssertTrue(UpdatePolicy.isNewer("2.18.1", than: "2.18.0"))
    }

    func testSemanticVersionAcceptsVPrefixAndShortTags() throws {
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("v2.18.1")), SemanticVersion("2.18.1"))
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("V2.18.1")), SemanticVersion("2.18.1"))
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("2.18"))?.description, "2.18.0")
        // Build metadata is ignored for precedence.
        XCTAssertEqual(try XCTUnwrap(SemanticVersion("2.18.1+42")), SemanticVersion("2.18.1"))
    }

    func testSemanticVersionOrdersPrereleasesBelowRelease() throws {
        let alpha = try XCTUnwrap(SemanticVersion("2.19.0-alpha.1"))
        let beta = try XCTUnwrap(SemanticVersion("2.19.0-beta.2"))
        let betaLater = try XCTUnwrap(SemanticVersion("2.19.0-beta.10"))
        let release = try XCTUnwrap(SemanticVersion("2.19.0"))
        XCTAssertLessThan(alpha, beta)
        XCTAssertLessThan(beta, betaLater)   // numeric identifiers compare by value
        XCTAssertLessThan(betaLater, release)
        XCTAssertFalse(UpdatePolicy.isNewer("2.19.0-beta.2", than: "2.19.0"))
        XCTAssertTrue(UpdatePolicy.isNewer("2.19.0", than: "2.19.0-beta.2"))
    }

    func testSemanticVersionRejectsMalformedTags() {
        for raw in ["", "v", "banana", "1.2.x", "1.2.3.4", "2.18.0-", "2.18..1", "-1.0.0"] {
            XCTAssertNil(SemanticVersion(raw), "\(raw) should not parse")
        }
    }

    func testAutomaticCheckWaitsTwentyFourHours() {
        let now = Date()
        XCTAssertTrue(UpdatePolicy.isCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.isCheckDue(
            lastCheck: now.addingTimeInterval(-23 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(UpdatePolicy.isCheckDue(
            lastCheck: now.addingTimeInterval(-25 * 60 * 60),
            now: now
        ))
    }

    func testNotificationIsOncePerVersion() {
        XCTAssertTrue(UpdatePolicy.shouldNotify(version: "2.18.1", lastNotified: nil))
        XCTAssertFalse(UpdatePolicy.shouldNotify(version: "2.18.1", lastNotified: "2.18.1"))
        XCTAssertTrue(UpdatePolicy.shouldNotify(version: "2.18.2", lastNotified: "2.18.1"))
    }

    func testBrewCommandUsesHomebrewCask() {
        XCTAssertEqual(UpdatePolicy.brewCommand, "brew update && brew upgrade --cask palette")
    }

    func testFailureBackoffGrowsAndCaps() {
        XCTAssertEqual(UpdatePolicy.retryDelay(failures: 0), 0)
        XCTAssertEqual(UpdatePolicy.retryDelay(failures: 1), 15 * 60)
        XCTAssertEqual(UpdatePolicy.retryDelay(failures: 2), 30 * 60)
        XCTAssertEqual(UpdatePolicy.retryDelay(failures: 20), UpdatePolicy.checkInterval)
        let now = Date()
        XCTAssertFalse(UpdatePolicy.isRetryAllowed(retryAfter: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(UpdatePolicy.isRetryAllowed(retryAfter: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(UpdatePolicy.isRetryAllowed(retryAfter: nil, now: now))
    }

    func testReleasePayloadParsingSkipsMalformedAnswers() {
        let json = #"{"tag_name":"v2.18.1","html_url":"https://github.com/Myleshen/palette/releases/tag/v2.18.1"}"#
        let release = UpdatePolicy.parseRelease(Data(json.utf8))
        XCTAssertEqual(release?.tag, "v2.18.1")
        XCTAssertEqual(release?.version.description, "2.18.1")
        XCTAssertEqual(release?.url.absoluteString, "https://github.com/Myleshen/palette/releases/tag/v2.18.1")

        XCTAssertNil(UpdatePolicy.parseRelease(Data(#"{"tag_name":"nightly"}"#.utf8)))
        XCTAssertNil(UpdatePolicy.parseRelease(Data("not json".utf8)))
    }

    func testUpdateConfigRoundTrips() throws {
        var config = PaletteConfig()
        XCTAssertTrue(config.updates.automatic)
        config.updates.automatic = false

        let table = try TOMLTable(string: ConfigWriter.render(config))
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertFalse(parsed.updates.automatic)
        XCTAssertTrue(diagnostics.isEmpty)

        XCTAssertTrue(ConfigLoader.defaultTOML().contains("[updates]"))
    }
}
