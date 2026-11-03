import XCTest
@testable import PalettePlatform
@testable import PaletteProviders

final class BitwardenTests: XCTestCase {
    func testOnlySessionErrorsClearTheCachedSession() {
        XCTAssertTrue(BitwardenProvider.looksLikeSessionFailure("Invalid session."))
        XCTAssertTrue(BitwardenProvider.looksLikeSessionFailure("You are not logged in."))
        XCTAssertTrue(BitwardenProvider.looksLikeSessionFailure("Vault is locked."))
        XCTAssertFalse(BitwardenProvider.looksLikeSessionFailure(""))
        XCTAssertFalse(BitwardenProvider.looksLikeSessionFailure("getaddrinfo ENOTFOUND vaultwarden.example"))
        XCTAssertFalse(BitwardenProvider.looksLikeSessionFailure("Request timed out"))
    }

    func testListIsCachedUntilCleared() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-bw-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("calls")
        let script = dir.appendingPathComponent("bw")

        try """
        #!/bin/sh
        echo x >> "\(counter.path)"
        printf '%s\\n' '[{"id":"1","name":"Test"}]'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let vault = BitwardenVault(persistCache: false)
        let first = await vault.list(bw: script.path, session: "session")
        XCTAssertNotNil(first.data)
        XCTAssertFalse(first.fromCache)
        let second = await vault.list(bw: script.path, session: "session")
        XCTAssertTrue(second.fromCache)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 1)

        let entry = await vault.entryData(id: "1")
        XCTAssertNotNil(entry)

        await vault.clear()
        let third = await vault.list(bw: script.path, session: "session")
        XCTAssertFalse(third.fromCache)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testRefreshForcesRefetch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-bw-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("calls")
        let script = dir.appendingPathComponent("bw")
        try """
        #!/bin/sh
        echo x >> "\(counter.path)"
        printf '%s\n' '[{"id":"1","name":"Test"}]'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let vault = BitwardenVault(persistCache: false)
        _ = await vault.list(bw: script.path, session: "session")
        let cached = await vault.list(bw: script.path, session: "session")
        XCTAssertTrue(cached.fromCache)
        await vault.refresh()
        let refreshed = await vault.list(bw: script.path, session: "session")
        XCTAssertFalse(refreshed.fromCache)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 2)
    }

    func testConcurrentListCallsShareOneProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-bw-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("calls")
        let script = dir.appendingPathComponent("bw")
        try """
        #!/bin/sh
        echo x >> "\(counter.path)"
        sleep 0.4
        printf '%s\n' '[{"id":"1","name":"Test"}]'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let vault = BitwardenVault(persistCache: false)
        async let first = vault.list(bw: script.path, session: "session")
        async let second = vault.list(bw: script.path, session: "session")
        let (one, two) = await (first, second)
        XCTAssertNotNil(one.data)
        XCTAssertNotNil(two.data)
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testLocalQueryMatching() {
        let entry: [String: Any] = [
            "name": "Test Login",
            "notes": "success if you can read it",
            "login": ["username": "test", "uris": [["uri": "https://example.com"]]],
        ]
        XCTAssertTrue(BitwardenProvider.matches(entry, query: "test"))
        XCTAssertTrue(BitwardenProvider.matches(entry, query: "example"))
        XCTAssertTrue(BitwardenProvider.matches(entry, query: "read"))
        XCTAssertFalse(BitwardenProvider.matches(entry, query: "missing"))
    }
}
