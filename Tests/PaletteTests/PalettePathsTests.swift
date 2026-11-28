import XCTest
import PaletteCore

final class PalettePathsTests: XCTestCase {
    private let debugID = "dev.myleshen.palette.debug"

    func testDebugBundleUsesIsolatedDirectories() {
        let paths = PalettePaths.resolve(environment: [:], home: "/home/me", bundleIdentifier: debugID)
        XCTAssertEqual(paths.configDir.path, "/home/me/Library/Application Support/Palette Debug/config")
        XCTAssertEqual(paths.stateDir.path, "/home/me/Library/Application Support/Palette Debug/state")
        XCTAssertEqual(paths.cacheDir.path, "/home/me/Library/Caches/Palette Debug")
    }

    func testEnvironmentOverridesWinOverDebugDirectories() {
        let paths = PalettePaths.resolve(
            environment: [
                "PALETTE_CONFIG_DIR": "/tmp/palette-debug-test/config",
                "PALETTE_STATE_DIR": "/tmp/palette-debug-test/state",
                "PALETTE_CACHE_DIR": "/tmp/palette-debug-test/cache",
            ],
            home: "/home/me",
            bundleIdentifier: debugID
        )
        XCTAssertEqual(paths.configDir.path, "/tmp/palette-debug-test/config")
        XCTAssertEqual(paths.stateDir.path, "/tmp/palette-debug-test/state")
        XCTAssertEqual(paths.cacheDir.path, "/tmp/palette-debug-test/cache")
    }

    func testOversizedConfigIsRefusedWithoutRewritingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-config-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try paths.createDirectories()
        let oversized = Data(repeating: 0x23, count: 4_000_001)
        try oversized.write(to: paths.configFile)

        let result = ConfigLoader.load(paths: paths)

        XCTAssertNotNil(result.parseError)
        XCTAssertTrue(
            result.diagnostics.contains { $0.message.contains("larger than 4 MB") },
            "\(result.diagnostics.map(\.message))"
        )
        XCTAssertEqual(try Data(contentsOf: paths.configFile), oversized)
    }

    func testReleaseBundleKeepsDefaultDirectories() {
        let paths = PalettePaths.resolve(environment: [:], home: "/home/me", bundleIdentifier: "dev.myleshen.palette")
        XCTAssertEqual(paths.configDir.path, "/home/me/.config/palette")
        XCTAssertEqual(paths.stateDir.path, "/home/me/.local/state/palette")
        XCTAssertEqual(paths.cacheDir.path, "/home/me/Library/Caches/Palette")
    }
}
