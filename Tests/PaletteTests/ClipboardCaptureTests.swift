import TOMLKit
import XCTest
import PaletteCore

final class ClipboardCaptureTests: XCTestCase {
    private let ignored: Set<String> = ["com.1password.1password", "com.apple.keychainaccess"]

    func testIgnoredFrontmostAppSkipsCapture() {
        XCTAssertFalse(ClipboardCapturePolicy.shouldCapture(
            frontmostBundleID: "com.1password.1password",
            ignoredApps: ignored,
            isMarkedSecret: false
        ))
    }

    func testUnlistedFrontmostAppStillCaptures() {
        XCTAssertTrue(ClipboardCapturePolicy.shouldCapture(
            frontmostBundleID: "com.apple.TextEdit",
            ignoredApps: ignored,
            isMarkedSecret: false
        ))
        XCTAssertTrue(ClipboardCapturePolicy.shouldCapture(
            frontmostBundleID: nil,
            ignoredApps: ignored,
            isMarkedSecret: false
        ))
    }

    func testConcealedCopyAlwaysWins() {
        // An allowed app marking one copy concealed, and an ignored app's
        // concealed copy, both stay out of history.
        XCTAssertFalse(ClipboardCapturePolicy.shouldCapture(
            frontmostBundleID: "com.apple.TextEdit",
            ignoredApps: ignored,
            isMarkedSecret: true
        ))
        XCTAssertFalse(ClipboardCapturePolicy.shouldCapture(
            frontmostBundleID: "com.1password.1password",
            ignoredApps: ignored,
            isMarkedSecret: true
        ))
    }

    func testIgnoredAppsRoundTripThroughConfig() throws {
        var config = PaletteConfig()
        config.clipboard.ignoredApps = ["com.1password.1password", "com.apple.Terminal"]
        let rendered = ConfigWriter.render(config)
        XCTAssertTrue(
            rendered.contains("ignored_apps = [\"com.1password.1password\", \"com.apple.Terminal\"]"),
            rendered
        )

        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(try TOMLTable(string: rendered), diagnostics: &diagnostics)
        XCTAssertEqual(parsed.clipboard.ignoredApps, config.clipboard.ignoredApps)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testIgnoredAppsParseDropsBlankEntries() throws {
        var config = PaletteConfig()
        config.clipboard.ignoredApps = [" com.1password.1password ", "", "com.apple.Terminal"]
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(
            try TOMLTable(string: ConfigWriter.render(config)),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(parsed.clipboard.ignoredApps, ["com.1password.1password", "com.apple.Terminal"])
    }

    func testCopyOnlyTargetsSkipTheSyntheticKeystroke() {
        let known = [
            "com.microsoft.rdc.macos",
            "com.citrix.receiver.icaviewer.mac",
            "com.parallels.desktop.console",
            "com.vmware.horizon",
        ]
        for bundleID in known {
            XCTAssertFalse(PasteTarget.synthesizesKeystroke(for: bundleID), bundleID)
        }
        XCTAssertTrue(PasteTarget.synthesizesKeystroke(for: "com.apple.Terminal"))
        XCTAssertTrue(PasteTarget.synthesizesKeystroke(for: nil))
    }
}
