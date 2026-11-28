import TOMLKit
import XCTest
import PaletteCore
@testable import PalettePlatform

/// macOS is never switched in tests; the engine's closure records the request.
@MainActor
final class SystemAppearanceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Bool] = []
        func append(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }
    }

    func testConfigRoundTripCarriesSystemAppearance() throws {
        var config = ThemingConfig()
        config.systemAppearance = .off
        let rendered = config.render()
        XCTAssertTrue(rendered.contains("system_appearance = \"off\""))
        let root = try TOMLTable(string: rendered)
        let parsed = ThemingConfig.parse(try XCTUnwrap(root.table("theming")))
        XCTAssertEqual(parsed.systemAppearance, ThemingSystemAppearance.off)
        XCTAssertEqual(ThemingConfig().systemAppearance, ThemingSystemAppearance.auto)
    }

    func testAutoSwitchesToThePaletteAppearance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-appearance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config", isDirectory: true),
            stateDir: root.appendingPathComponent("state", isDirectory: true),
            cacheDir: root.appendingPathComponent("cache", isDirectory: true)
        )
        let recorder = Recorder()
        let engine = ThemingEngine(
            paths: paths,
            themesDirectory: paths.themesDir,
            chromiumProbe: ThemingEngine.ChromiumProbe(
                installed: { [] }, isRunning: { _ in false },
                silentActive: { _ in false }, legacyProfile: { _ in false }
            ),
            reloadsEnabled: false,
            setSystemAppearance: { dark in
                recorder.append(dark)
                return true
            }
        )
        var config = ThemingConfig()
        config.enabled = true
        config.source = .theme
        config.targets = []
        config.systemAppearance = .auto

        _ = await engine.applyTheme(named: "default-light", config: config)
        XCTAssertEqual(recorder.values, [false], "a light palette asks for light macOS")

        config.systemAppearance = .off
        _ = await engine.applyTheme(named: "default-dark", config: config)
        XCTAssertEqual(recorder.values, [false], "off never asks")
    }
}
