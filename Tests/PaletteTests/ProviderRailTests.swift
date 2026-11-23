import XCTest
@testable import PaletteCore

final class ProviderRailTests: XCTestCase {
    private let github = ProviderGroup(id: "github", name: "GitHub", order: 10)
    private let bitwarden = ProviderGroup(id: "bitwarden", name: "Bitwarden", order: 20)

    private func descriptor(
        _ id: String,
        trigger: String?,
        group: ProviderGroup? = nil,
        shortName: String? = nil,
        icon: String? = nil
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            name: id,
            trigger: trigger,
            icon: icon,
            group: group,
            shortName: shortName
        )
    }

    private var descriptors: [ProviderDescriptor] {
        [
            descriptor("apps", trigger: nil, icon: "symbol:app"),
            descriptor("gh", trigger: "gh", group: github, shortName: "Overview", icon: "symbol:code"),
            descriptor("ghp", trigger: "ghp", group: github, shortName: "PRs"),
            descriptor("ghi", trigger: "ghi", group: github, shortName: "Issues"),
            descriptor("bw", trigger: "bw", group: bitwarden, shortName: "Passwords", icon: "symbol:key"),
            descriptor("bwu", trigger: "bwu", group: bitwarden, shortName: "Usernames"),
            descriptor("clip", trigger: "clip", icon: "symbol:doc.on.clipboard"),
        ]
    }

    func testEntriesAreEverythingAppsGroupsThenUngrouped() {
        let entries = ProviderRail.entries(for: descriptors)
        XCTAssertEqual(
            entries.map(\.id),
            ["everything", "apps", "group:github", "group:bitwarden", "clip"]
        )
        XCTAssertEqual(entries[0].title, "Everything")
        XCTAssertEqual(entries[1].title, "Apps")
        XCTAssertEqual(entries[1].scopeProviderID, "apps")
        XCTAssertEqual(entries[1].icon, "symbol:app")
    }

    func testGroupUsesItsNameAndFirstMembersIcon() throws {
        let entries = ProviderRail.entries(for: descriptors)
        let githubEntry = try XCTUnwrap(entries.first { $0.id == "group:github" })
        let bitwardenEntry = entries.first { $0.id == "group:bitwarden" }
        XCTAssertEqual(githubEntry.title, "GitHub")
        XCTAssertEqual(githubEntry.icon, "symbol:code")
        XCTAssertNil(githubEntry.trigger)
        XCTAssertEqual(bitwardenEntry?.title, "Bitwarden")
        XCTAssertEqual(bitwardenEntry?.icon, "symbol:key")
        XCTAssertTrue(githubEntry.isGroup)
    }

    func testGroupMembershipKeepsTriggersAndShortNames() {
        let entries = ProviderRail.entries(for: descriptors)
        let bitwardenEntry = entries.first { $0.id == "group:bitwarden" }
        XCTAssertEqual(bitwardenEntry?.children.map(\.id), ["bw", "bwu"])
        XCTAssertEqual(bitwardenEntry?.children.map(\.trigger), ["bw", "bwu"])
        XCTAssertEqual(bitwardenEntry?.children.map(\.title), ["Passwords", "Usernames"])
        XCTAssertEqual(bitwardenEntry?.children.first?.trigger, "bw")

        let githubEntry = entries.first { $0.id == "group:github" }
        XCTAssertEqual(githubEntry?.children.map(\.id), ["gh", "ghp", "ghi"])
        XCTAssertEqual(githubEntry?.children.map(\.trigger), ["gh", "ghp", "ghi"])
    }

    func testRailIDMapsAProviderToItsGroup() {
        let entries = ProviderRail.entries(for: descriptors)
        XCTAssertEqual(ProviderRail.railID(for: "ghp", in: entries), "group:github")
        XCTAssertEqual(ProviderRail.railID(for: "bwu", in: entries), "group:bitwarden")
        XCTAssertEqual(ProviderRail.railID(for: "clip", in: entries), "clip")
    }

    func testGroupsSortByOrderNotFirstAppearance() {
        let late = ProviderGroup(id: "late", name: "Late", order: 30)
        let early = ProviderGroup(id: "early", name: "Early", order: 5)
        let entries = ProviderRail.entries(for: [
            descriptor("a", trigger: "a", group: late),
            descriptor("b", trigger: "b", group: early),
        ])
        XCTAssertEqual(entries.dropFirst(2).map(\.id), ["group:early", "group:late"])
    }

    func testTriggerlessGroupMembersDoNotBecomeRows() {
        let entries = ProviderRail.entries(for: [
            descriptor("apps", trigger: nil),
            descriptor("ghost", trigger: nil, group: github),
        ])
        XCTAssertEqual(entries.map(\.id), ["everything", "apps"])
    }
}
