import XCTest
@testable import PalettePlatform

final class ToolLocatorTests: XCTestCase {
    func testMissingToolIsCachedUntilConfigure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", directory.path, 1)
        defer { setenv("PATH", originalPath ?? "/usr/bin:/bin", 1) }

        let tool = "palette-absent-\(UUID().uuidString)"
        let locator = ToolLocator()
        XCTAssertNil(locator.path(for: tool))

        // A negative result lasts the session: installing the tool later is
        // not seen until `configure` invalidates the cache.
        let executable = directory.appendingPathComponent(tool)
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertNil(locator.path(for: tool))

        locator.configure(extraPaths: [directory.path])
        XCTAssertEqual(locator.path(for: tool), executable.path)
    }
}
