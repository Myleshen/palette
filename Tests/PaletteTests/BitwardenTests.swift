import XCTest
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
}
