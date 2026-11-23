import XCTest
@testable import PalettePlatform

final class WebAppLauncherTests: XCTestCase {
    func testProfileLaunchExposesWindowsToAccessibilityOnce() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/app"))
        let profile = URL(fileURLWithPath: "/tmp/palette-profile")

        let arguments = WebAppLauncher.arguments(url: url, profile: profile)

        XCTAssertEqual(arguments.filter { $0 == "--force-renderer-accessibility" }.count, 1)
        XCTAssertTrue(arguments.contains("--app=https://example.com/app"))
        XCTAssertTrue(arguments.contains("--user-data-dir=/tmp/palette-profile"))
    }
}
