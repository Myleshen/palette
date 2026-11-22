import XCTest
import PaletteCore
import PalettePlatform

final class ProcessRunnerTests: XCTestCase {
    func testSanitizedEnvironmentDropsSecretsButKeepsAdditions() {
        let clean = ProcessRunner.sanitizedEnvironment([
            "OPENCODE_GO_API_KEY": "a",
            "NVIDIA_API_KEY": "b",
            "PALETTE_ASK_KEY": "c",
            "BW_SESSION": "d",
            "BW_PASSWORD": "e",
            "PALETTE_PROVIDER_ID": "kept",
        ])
        XCTAssertNil(clean["OPENCODE_GO_API_KEY"])
        XCTAssertNil(clean["NVIDIA_API_KEY"])
        XCTAssertNil(clean["PALETTE_ASK_KEY"])
        XCTAssertNil(clean["BW_SESSION"])
        XCTAssertNil(clean["BW_PASSWORD"])
        XCTAssertEqual(clean["PALETTE_PROVIDER_ID"], "kept")
    }

    func testChildProcessPrintsNoInheritedSecretNames() async throws {
        let names = ProcessRunner.secretEnvironmentNames
        for name in names { setenv(name, "leak-\(name)", 1) }
        defer { for name in names { unsetenv(name) } }

        let result = try await ProcessRunner.run(
            ["/usr/bin/env"],
            environment: ["PALETTE_PROVIDER_ID": "test"],
            timeout: 10
        )
        XCTAssertEqual(result.status, 0)
        let output = result.stdoutString
        for name in names {
            XCTAssertFalse(output.contains("\(name)="), "\(name) leaked into the child environment")
        }
        XCTAssertTrue(output.contains("PALETTE_PROVIDER_ID=test"))
    }

    /// A child that leaves `sleep` holding stdout must not hang the runner.
    func testGrandchildHoldingStdoutDoesNotHang() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            ["/bin/sh", "-c", "sleep 30 & exit 0"],
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(elapsed, 2.0, "the runner waited for a grandchild that held the pipe")
    }

    func testTimeoutKillsTheWholeProcessGroup() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            ["/bin/sh", "-c", "sleep 30 & sleep 30"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 3.5)
    }
}
