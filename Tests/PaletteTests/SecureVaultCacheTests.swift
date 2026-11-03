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
}
