import AppKit
import XCTest
import PaletteCore
import PalettePlatform
import PaletteProviders
import PaletteRuntime
@testable import PaletteApp

/// Drives the real `SearchController` and `AskWindowController` against a
/// sandbox home, the way the panel does. These replace the scripted e2e flows
/// that only proved "a window opened": the assertions here are on controller
/// state, so a broken mode switch fails the suite instead of an earlier row
/// count.
@MainActor
final class ControllerIntegrationTests: XCTestCase {
    private var root: URL!
    private var paths: PalettePaths!
    private var store: PaletteStore!
    private var themeManager: ThemeManager!
    private var controller: SearchController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-controller-\(UUID().uuidString)", isDirectory: true)
        paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config", isDirectory: true),
            stateDir: root.appendingPathComponent("state", isDirectory: true),
            cacheDir: root.appendingPathComponent("cache", isDirectory: true)
        )
        try paths.createDirectories()
        store = try PaletteStore(path: paths.databaseFile.path)
        themeManager = ThemeManager(paths: paths, selection: ThemeSelection(), store: store)
        controller = SearchController(
            registry: ProviderRegistry(providers: [], prefix: "/"),
            configuration: PaletteConfig(),
            paths: paths,
            store: store,
            launcher: LauncherService(),
            pasteboard: PasteboardService(),
            themeManager: themeManager,
            clipboardMonitor: nil
        )
    }

    override func tearDown() {
        controller = nil
        themeManager = nil
        store = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// The `empty-query-reset` flow: a hidden panel comes back empty and on the
    /// first row, rather than restoring the last query.
    func testHidingThePanelDropsTheQueryAndSelection() {
        controller.query = "safari"
        controller.selectionIndex = 3

        controller.panelDidHide()

        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.selectionIndex, 0)
        XCTAssertTrue(controller.items.isEmpty)

        controller.panelDidShow()
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.selectionIndex, 0)
        XCTAssertFalse(controller.scratchpadActive)
        XCTAssertFalse(controller.terminalActive)
    }

    /// One content area: opening a mode closes the previous one instead of
    /// leaving two active flags for the view to disambiguate.
    func testOpeningAModeClosesThePreviousContent() {
        controller.openScratchpad()
        XCTAssertTrue(controller.scratchpadActive)
        XCTAssertFalse(controller.terminalActive)
        XCTAssertFalse(controller.previewEnabled)

        controller.openTerminalPanel(command: "sleep 5")
        XCTAssertTrue(controller.terminalActive)
        XCTAssertFalse(controller.scratchpadActive, "terminal replaces the scratchpad")
        XCTAssertFalse(controller.previewEnabled)

        controller.openScratchpad()
        XCTAssertTrue(controller.scratchpadActive)
        XCTAssertFalse(controller.terminalActive, "scratchpad replaces the terminal")
        XCTAssertFalse(controller.previewEnabled)

        controller.openClipboard()
        XCTAssertTrue(controller.previewEnabled)
        XCTAssertFalse(controller.scratchpadActive, "the clipboard preview replaces the scratchpad")
        XCTAssertFalse(controller.terminalActive)
    }

    /// Ask lives in its own window. Opening and closing it must leave the
    /// panel's scratchpad and its draft exactly where they were.
    func testAskWindowLeavesThePanelContentAlone() {
        controller.openScratchpad(seed: "half-written note")
        XCTAssertTrue(controller.scratchpadActive)
        XCTAssertEqual(controller.scratchpadText, "half-written note")

        // Quiet presentation keeps the test from activating the app or asking
        // for notification permission the way a real window would.
        setenv("PALETTE_SCRIPT", "1", 1)
        defer { unsetenv("PALETTE_SCRIPT") }
        let ask = AskWindowController(
            service: AskService(store: store, configuration: AskConfig(), environment: [:]),
            question: "",
            model: AskModel(id: "test", name: "Test", endpoint: .opencodeGo, free: true),
            themeManager: themeManager,
            notify: false,
            onOpenSettings: {}
        )
        ask.show(below: nil)
        XCTAssertTrue(controller.scratchpadActive, "opening Ask must not tear down the panel")
        XCTAssertEqual(controller.scratchpadText, "half-written note")

        ask.close()
        XCTAssertTrue(controller.scratchpadActive)
        XCTAssertEqual(controller.scratchpadText, "half-written note")
    }
}
