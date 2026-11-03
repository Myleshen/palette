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

    func testHammerspoonExport() {
        let apps = [
            WebApp(id: "1", name: "Figma", url: "https://figma.com", createdAt: Date(), shortcut: "ctrl+alt+f"),
            WebApp(id: "2", name: "No Key", url: "https://example.com", createdAt: Date()),
        ]
        let text = HammerspoonExport.render(apps, browser: "Helium")
        XCTAssertTrue(text.contains("name = \"Figma\", url = \"https://figma.com\", shortcut = \"ctrl+alt+f\""))
        XCTAssertTrue(text.contains("name = \"No Key\", url = \"https://example.com\""))
        XCTAssertFalse(text.contains("No Key\", url = \"https://example.com\", shortcut"))
        if ToolLocator.shared.appPath(named: "Helium") != nil {
            XCTAssertTrue(text.contains("browser_path = \"/Applications/Helium.app/Contents/MacOS/Helium\""))
            XCTAssertTrue(text.contains("--app=https://figma.com"))
            XCTAssertTrue(text.contains("--user-data-dir="))
        }
    }

    func testStoreAddDedupeAndDelete() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-webapps-\(UUID().uuidString).sqlite")
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
}
