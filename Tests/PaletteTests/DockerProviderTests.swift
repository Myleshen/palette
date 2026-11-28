import XCTest
@testable import PaletteProviders

final class DockerProviderTests: XCTestCase {
    func testLogsCommandQuotesTheContainerName() {
        let command = DockerProvider.logsCommand(docker: "/opt/homebrew/bin/docker", name: "web; rm -rf ~")
        XCTAssertEqual(command, "'/opt/homebrew/bin/docker' logs -f 'web; rm -rf ~'")
        XCTAssertFalse(command.contains("logs -f web;"), "the name must not escape its quotes")
    }
}
