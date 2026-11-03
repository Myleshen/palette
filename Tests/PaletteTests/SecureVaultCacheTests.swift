import XCTest
@testable import PalettePlatform

final class SecureVaultCacheTests: XCTestCase {
    func testRoundTripAndSixHourExpiry() throws {
        let scope = "palette-test-\(UUID().uuidString)"
        defer { SecureVaultCache.remove(scope: scope) }
        let payload = Data(#"[{"id":"1","name":"Test"}]"#.utf8)
        SecureVaultCache.save(data: payload, email: "test@example.com", scope: scope)

        let loaded = try XCTUnwrap(SecureVaultCache.load(scope: scope))
        XCTAssertEqual(loaded.data, payload)
        XCTAssertEqual(loaded.email, "test@example.com")

        let expired = Date().addingTimeInterval(SecureVaultCache.ttl + 1)
        XCTAssertNil(SecureVaultCache.load(scope: scope, now: expired))
        XCTAssertNil(SecureVaultCache.load(scope: scope), "An expired cache should be deleted")
    }

    func testScopeIsolatesClIProfiles() {
        XCTAssertNotEqual(
            SecureVaultCache.scope(environment: ["BITWARDENCLI_APPDATA_DIR": "/tmp/a"]),
            SecureVaultCache.scope(environment: ["BITWARDENCLI_APPDATA_DIR": "/tmp/b"])
        )
    }

    func testSessionRoundTripAndSixHourExpiry() throws {
        let scope = "palette-session-\(UUID().uuidString)"
        defer {
            SecureVaultCache.removeSession(scope: scope)
            SecureVaultCache.remove(scope: scope)
        }
        SecureVaultCache.saveSession("session-key-123", scope: scope)
        let loaded = try XCTUnwrap(SecureVaultCache.loadSession(scope: scope))
        XCTAssertEqual(loaded.session, "session-key-123")

        // The session and the vault snapshot must not share a file.
        let payload = Data(#"[{"id":"1"}]"#.utf8)
        SecureVaultCache.save(data: payload, email: "test@example.com", scope: scope)
        XCTAssertEqual(try XCTUnwrap(SecureVaultCache.load(scope: scope)).data, payload)
        XCTAssertEqual(try XCTUnwrap(SecureVaultCache.loadSession(scope: scope)).session, "session-key-123")

        let expired = Date().addingTimeInterval(SecureVaultCache.ttl + 1)
        XCTAssertNil(SecureVaultCache.loadSession(scope: scope, now: expired))
        XCTAssertNil(SecureVaultCache.loadSession(scope: scope), "An expired session should be deleted")
    }
}
