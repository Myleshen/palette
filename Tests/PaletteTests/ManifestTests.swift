import XCTest
import Foundation
import PaletteCore
import PaletteRuntime

final class ManifestTests: XCTestCase {
    func testBundledStyleManifestParses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("provider.toml")
        try """
        id = "neo"
        name = "Neovide Directories"
        trigger = "neo"
        engine = "paths"
        kind = "directories"
        scope = "projects"
        open_with = "neovide"
        priority = 60
        """.write(to: url, atomically: true, encoding: .utf8)

        var diagnostics: [Diagnostic] = []
        let manifest = ManifestLoader.parse(url: url, diagnostics: &diagnostics)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.id, "neo")
        XCTAssertEqual(manifest?.paths?.kind, .directories)
        XCTAssertEqual(manifest?.priority, 60)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testInvalidManifestReportsDiagnostic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("provider.toml")
        try """
        id = "Broken ID"
        command = ["echo"]
        """.write(to: url, atomically: true, encoding: .utf8)

        var diagnostics: [Diagnostic] = []
        XCTAssertNil(ManifestLoader.parse(url: url, diagnostics: &diagnostics))
        XCTAssertFalse(diagnostics.isEmpty)
    }
}
