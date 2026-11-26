import Darwin
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

    /// fzf or a provider can close stdin while Palette is still writing. The
    /// helper must stop at the short write instead of spinning; SIGPIPE is
    /// ignored at startup, and the injected writer proves the loop without
    /// raising a real signal.
    func testWriteAllStopsAtAShortWrite() {
        var calls = 0
        let written = ProcessRunner.writeAll(Data(repeating: 7, count: 100), to: -1) { _, count in
            calls += 1
            // First write takes 8 bytes, then the child is gone (EPIPE).
            return calls == 1 ? min(8, count) : -1
        }
        XCTAssertEqual(written, 8)
        XCTAssertEqual(calls, 2)
    }

    func testWriteAllWritesEverythingWhenTheChildReads() {
        let data = Data(repeating: 7, count: 1000)
        let written = ProcessRunner.writeAll(data, to: -1) { _, count in count }
        XCTAssertEqual(written, data.count)
    }

    /// End to end through the real pipe: a child that exits without reading
    /// leaves a short write, which is logged instead of raising SIGPIPE.
    func testClosedStdinIsLoggedAndDoesNotRaiseSIGPIPE() async throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previous) }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-process-log-\(UUID().uuidString).log")
        Log.shared.configure(url: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let payload = Data(repeating: 7, count: 1_000_000)
        let result = try await ProcessRunner.run(["/usr/bin/true"], stdin: payload, timeout: 10)
        XCTAssertEqual(result.status, 0)

        var logged = ""
        for _ in 0..<50 {
            logged = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if logged.contains("closed stdin after") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            logged.contains("closed stdin after"),
            "the short write was not logged: \(logged.debugDescription)"
        )
        XCTAssertTrue(logged.contains("of 1000000 bytes"))
    }

    func testStreamDeliversStdoutChunks() async throws {
        var received = Data()
        let result = try await ProcessRunner.stream(["/bin/sh", "-c", "printf 'a\\0b\\0c'"]) { chunk in
            received.append(contentsOf: chunk)
            return true
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(FDEnumerator.splitNUL(received), ["a", "b", "c"])
    }
}
