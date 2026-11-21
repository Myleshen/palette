import XCTest
@testable import PaletteProviders

final class SSHProviderTests: XCTestCase {
    func testSessionNameKeepsSafeCharacters() {
        XCTAssertEqual(SSHProvider.sessionName(for: "prod"), "prod")
        XCTAssertEqual(SSHProvider.sessionName(for: "deploy@10.0.0.5"), "deploy-10.0.0.5")
        XCTAssertEqual(SSHProvider.sessionName(for: "host:us/east"), "host-us-east")
        XCTAssertEqual(SSHProvider.sessionName(for: ""), "host")
    }
}
