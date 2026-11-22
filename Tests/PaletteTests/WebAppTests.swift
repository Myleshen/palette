import XCTest
@testable import PaletteCore
@testable import PalettePlatform
@testable import PaletteProviders

final class WebAppTests: XCTestCase {
    func testURLNormalization() {
        XCTAssertEqual(WebAppURL.normalize("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(WebAppURL.normalize("https://example.com/app")?.absoluteString, "https://example.com/app")
        XCTAssertEqual(WebAppURL.normalize("HTTP://EXAMPLE.COM")?.host, "EXAMPLE.COM")
        XCTAssertNil(WebAppURL.normalize("hello world"))
        XCTAssertNil(WebAppURL.normalize("2.5"))
        XCTAssertNil(WebAppURL.normalize("example"))
    }

    func testDefaultName() throws {
        let url = try XCTUnwrap(WebAppURL.normalize("https://www.figma.com/files"))
        XCTAssertEqual(WebAppURL.defaultName(for: url), "Figma")
    }

    func testShortcutParsing() {
        XCTAssertEqual(WebAppShortcut.parse("ctrl+alt+f")?.canonical, "ctrl+alt+f")
        XCTAssertEqual(WebAppShortcut.parse("ALT + CTRL + F")?.canonical, "ctrl+alt+f")
        XCTAssertEqual(WebAppShortcut.parse("command+option+1")?.canonical, "alt+cmd+1")
        XCTAssertEqual(WebAppShortcut.parse("cmd+shift+enter")?.canonical, "shift+cmd+return")
        XCTAssertNil(WebAppShortcut.parse("ctrl+f"))
        XCTAssertNil(WebAppShortcut.parse("ctrl+alt"))
        XCTAssertNil(WebAppShortcut.parse("ctrl+alt+notakey"))
    }

    func testStoreAddDedupeAndDelete() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-web-apps-\(UUID().uuidString).sqlite")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try PaletteStore(path: path)
        let first = try await store.addWebApp(name: "Figma", url: "https://figma.com", shortcut: "ctrl+alt+f")
        let same = try await store.addWebApp(name: "Figma Files", url: "https://figma.com")
        XCTAssertEqual(first.id, same.id)
        XCTAssertEqual(same.name, "Figma Files")
        XCTAssertEqual(same.shortcut, "ctrl+alt+f")

        try await store.updateWebAppShortcut(id: first.id, shortcut: "ctrl+alt+g")
        let updated = try await store.webApps()
        XCTAssertEqual(updated.first?.shortcut, "ctrl+alt+g")

        let all = try await store.webApps()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.url, "https://figma.com")

        try await store.deleteWebApp(id: first.id)
        let empty = try await store.webApps()
        XCTAssertTrue(empty.isEmpty)
    }

    func testSearchReturnsWithoutWaitingForFavicons() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-web-apps-\(UUID().uuidString).sqlite")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try PaletteStore(path: path)
        // Non-routable hosts: an await on their icons would take the 2.5 s
        // timeout each, which is what used to block the whole search.
        for index in 1...12 {
            _ = try await store.addWebApp(name: "App \(index)", url: "https://10.255.255.\(index)")
        }

        let provider = WebAppProvider(store: store, bridge: SilentWebAppBridge(), favicons: true)
        let started = Date()
        let items = try await provider.search(SearchRequest(text: "", isBound: true))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(items.count, 12)
        XCTAssertLessThan(elapsed, 2, "rows must come back before site icons are fetched")
    }
}

private actor SilentWebAppBridge: HostBridge {
    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }
    func notify(_ message: String) async {}
    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}
