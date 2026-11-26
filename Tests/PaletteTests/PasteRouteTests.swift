import XCTest
import PaletteCore

/// The paste route decides whether an Accessibility menu press, a synthetic
/// keystroke, or a copy-only fallback is used.
final class PasteRouteTests: XCTestCase {
    func testAMenuMakesAnyGUIAppUseTheAccessibilityPress() {
        XCTAssertEqual(PasteTarget.route(bundleID: "com.apple.TextEdit", menuAvailable: true), .menu)
        XCTAssertEqual(PasteTarget.route(bundleID: nil, menuAvailable: true), .menu)
    }

    func testAGUIAppWithoutAMenuFallsBackToTheKeystroke() {
        XCTAssertEqual(PasteTarget.route(bundleID: "com.apple.TextEdit", menuAvailable: false), .keystroke)
    }

    func testTerminalsWithAMenuUseIt() {
        for bundleID in ["org.neovide.neovide", "net.kovidgoyal.kitty", "com.mitchellh.ghostty"] {
            XCTAssertEqual(
                PasteTarget.route(bundleID: bundleID, menuAvailable: true),
                .menu,
                bundleID
            )
        }
    }

    func testNeovideWithoutAMenuGetsTheClipboardOnly() {
        XCTAssertEqual(
            PasteTarget.route(bundleID: "org.neovide.neovide", menuAvailable: false),
            .copyOnly
        )
    }

    func testOtherTerminalsWithoutAMenuStillGetTheKeystroke() {
        for bundleID in [
            "net.kovidgoyal.kitty",
            "com.googlecode.iterm2",
            "dev.wez.wezterm",
            "org.alacritty",
            "com.mitchellh.ghostty",
            "co.zeit.hyper",
        ] {
            XCTAssertEqual(
                PasteTarget.route(bundleID: bundleID, menuAvailable: false),
                .keystroke,
                bundleID
            )
        }
    }

    func testRemoteDesktopTargetsStayCopyOnlyEvenWithAMenu() {
        for bundleID in PasteTarget.copyOnlyBundleIDs {
            XCTAssertEqual(
                PasteTarget.route(bundleID: bundleID, menuAvailable: true),
                .copyOnly,
                bundleID
            )
        }
    }

    func testAnImageInATerminalKeepsTheControlVPastePath() {
        XCTAssertEqual(
            PasteTarget.route(bundleID: "net.kovidgoyal.kitty", menuAvailable: true, image: true),
            .keystroke
        )
        XCTAssertEqual(
            PasteTarget.route(bundleID: "org.neovide.neovide", menuAvailable: true, image: true),
            .menu
        )
    }
}
