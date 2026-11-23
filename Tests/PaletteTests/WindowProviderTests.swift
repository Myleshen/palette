import CoreGraphics
import XCTest
@testable import PaletteProviders

final class WindowProviderTests: XCTestCase {
    private func raw(
        number: Int,
        pid: pid_t,
        app: String = "Xcode",
        title: String? = nil,
        frame: CGRect,
        alpha: Double = 1
    ) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowLayer as String: 0,
            kCGWindowOwnerPID as String: pid,
            kCGWindowOwnerName as String: app,
            kCGWindowNumber as String: number,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: [
                "X": frame.origin.x,
                "Y": frame.origin.y,
                "Width": frame.size.width,
                "Height": frame.size.height,
            ] as [String: CGFloat],
        ]
        if let title { entry[kCGWindowName as String] = title }
        return entry
    }

    func testSameSizeUntitledWindowsBothSurvive() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let list = [
            raw(number: 11, pid: 42, title: nil, frame: frame),
            raw(number: 12, pid: 42, title: nil, frame: frame.offsetBy(dx: 100, dy: 100)),
        ]

        let entries = WindowProvider.entries(from: list)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.key)).count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.number)), [11, 12])
    }

    func testTheSameWindowListedTwiceIsDeduped() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let list = [
            raw(number: 11, pid: 42, title: "Inbox", frame: frame),
            raw(number: 11, pid: 42, title: "Inbox", frame: frame),
        ]

        XCTAssertEqual(WindowProvider.entries(from: list).count, 1)
    }

    func testHelperWindowsAreSkipped() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let list = [
            raw(number: 1, pid: 42, title: "Visible", frame: frame),
            raw(number: 2, pid: 42, title: "Helper", frame: frame, alpha: 0),
            raw(number: 3, pid: 42, title: "Tiny", frame: CGRect(x: 0, y: 0, width: 30, height: 30)),
        ]

        let entries = WindowProvider.entries(from: list)

        XCTAssertEqual(entries.map(\.title), ["Visible"])
    }

    func testTitleFallbackPicksTheWindowAtTheSameFrame() {
        let windows = [
            TitledWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Inbox"),
            TitledWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600), title: "Drafts"),
        ]

        let near = CGRect(x: 1, y: 1, width: 800, height: 600)
        XCTAssertEqual(WindowTitleResolver.match(frame: near, in: windows), "Inbox")
        XCTAssertNil(WindowTitleResolver.match(frame: CGRect(x: 900, y: 0, width: 800, height: 600), in: [windows[0]]))
        XCTAssertNil(WindowTitleResolver.match(frame: CGRect(x: 5, y: 0, width: 800, height: 600), in: [windows[0]]))
    }

    func testResolverUsesAXTitlesWhenTrusted() async {
        let resolver = WindowTitleResolver(
            source: FakeTitleSource(windows: [
                42: [TitledWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Inbox")]
            ]),
            isTrusted: { true }
        )

        let title = await resolver.title(for: CGRect(x: 0, y: 0, width: 800, height: 600), pid: 42)

        XCTAssertEqual(title, "Inbox")
    }

    func testResolverSkipsAXWithoutAccessibility() async {
        let resolver = WindowTitleResolver(
            source: FakeTitleSource(windows: [
                42: [TitledWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Inbox")]
            ]),
            isTrusted: { false }
        )

        let title = await resolver.title(for: CGRect(x: 0, y: 0, width: 800, height: 600), pid: 42)

        XCTAssertNil(title)
    }

    func testUntitledRowUsesAppNameAndSize() {
        let row = WindowProvider.row(
            title: "",
            appName: "Safari",
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(row.title, "Untitled window")
        XCTAssertEqual(row.subtitle, "Safari · 1440×900")
    }

    func testTitledRowKeepsTheAppInTheSubtitle() {
        let row = WindowProvider.row(
            title: "Inbox",
            appName: "Safari",
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(row.title, "Inbox")
        XCTAssertEqual(row.subtitle, "Safari")
    }
}

private struct FakeTitleSource: WindowTitleSource {
    var windows: [pid_t: [TitledWindow]]

    func titledWindows(for pid: pid_t) -> [TitledWindow] {
        windows[pid] ?? []
    }
}
