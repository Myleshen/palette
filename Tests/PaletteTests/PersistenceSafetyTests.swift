import Foundation
import XCTest
@testable import PaletteCore
@testable import PalettePlatform

/// Rules that keep state on disk across a quit or a crash: the global-provider
/// migration, the config backup, the clipboard clear, and recording adoption.
final class PersistenceSafetyTests: XCTestCase {
    private func makePaths() throws -> (PalettePaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        return (paths, root)
    }

    // MARK: - Global provider migration

    func testUnversionedGlobalListWidensToDefaultsAndKeepsExtras() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [providers]
        global = ["system", "timer", "awake", "emoji"]
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        let config = ConfigLoader.load(paths: paths).config
        for id in ["calc", "search", "web", "win", "system", "timer", "awake"] {
            XCTAssertTrue(config.globalProviders.contains(id), "\(id) answers a plain query")
        }
        XCTAssertTrue(config.globalProviders.contains("emoji"), "the user's extra survives")
        XCTAssertEqual(Set(config.globalProviders).count, config.globalProviders.count, "no duplicates")
    }

    func testUnversionedNarrowListOfDefaultIdsIsKept() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [providers]
        global = ["calc", "web"]
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConfigLoader.load(paths: paths).config.globalProviders, ["calc", "web"])
    }

    func testVersionedGlobalListIsAuthoritative() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [meta]
        config_version = 2

        [providers]
        global = ["calc"]
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConfigLoader.load(paths: paths).config.globalProviders, ["calc"])
    }

    func testExplicitEmptyGlobalStaysEmpty() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [providers]
        global = []
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConfigLoader.load(paths: paths).config.globalProviders, [])
    }

    func testRendererWritesSchemaVersion() {
        XCTAssertTrue(ConfigWriter.render(PaletteConfig()).contains("config_version = 2"))
    }

    // MARK: - Config backup and parse errors

    func testWriteKeepsExactPreviousBytesAsBackup() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = """
        # my comment
        [providers]
        global = ["calc"]

        [my_unknown_table]
        mystery = 42
        """
        try original.write(to: paths.configFile, atomically: true, encoding: .utf8)

        var updated = PaletteConfig()
        updated.providerPrefix = "!"
        try ConfigWriter.write(updated, to: paths.configFile)

        let backup = try String(contentsOf: ConfigWriter.backupURL(for: paths.configFile), encoding: .utf8)
        XCTAssertEqual(backup, original)
        XCTAssertTrue(try String(contentsOf: paths.configFile, encoding: .utf8).contains("provider_prefix = \"!\""))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: ConfigWriter.backupURL(for: paths.configFile).path
        )[.posixPermissions] as? Int
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)

        // A second save rolls the backup forward: it holds the previous write,
        // never the original forever.
        let firstRender = try String(contentsOf: paths.configFile, encoding: .utf8)
        updated.providerPrefix = "?"
        try ConfigWriter.write(updated, to: paths.configFile)
        let secondBackup = try String(contentsOf: ConfigWriter.backupURL(for: paths.configFile), encoding: .utf8)
        XCTAssertEqual(secondBackup, firstRender)
    }

    func testParseErrorIsReportedWithBackupPath() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try "not [ valid toml".write(to: paths.configFile, atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(paths: paths)
        let message = try XCTUnwrap(result.parseError)
        XCTAssertTrue(message.contains("config.toml has an error"))
        XCTAssertTrue(message.contains("config.toml.bak"))
        XCTAssertFalse(result.createdDefault)
    }

    // MARK: - Clipboard clear

    func testClipboardClearOnlyFiresWhenDueAndMatching() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = PendingClipboardClear(expiresAt: 1_010, hash: "abc", changeCount: 4)

        XCTAssertFalse(pending.shouldClear(currentHash: "abc", at: now), "not due yet")
        XCTAssertTrue(pending.shouldClear(currentHash: "abc", at: now.addingTimeInterval(11)))
        XCTAssertFalse(pending.shouldClear(currentHash: "other", at: now.addingTimeInterval(11)))
        XCTAssertFalse(pending.shouldClear(currentHash: nil, at: now.addingTimeInterval(11)))
    }

    func testClipboardDigestMatchesSHA256() {
        XCTAssertEqual(
            PasteboardService.digest(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testPendingClipboardClearRoundTrips() throws {
        let pending = PendingClipboardClear(expiresAt: 42.5, hash: "deadbeef", changeCount: 7)
        let decoded = try JSONDecoder().decode(
            PendingClipboardClear.self,
            from: JSONEncoder().encode(pending)
        )
        XCTAssertEqual(decoded, pending)
    }

    // MARK: - Recording adoption

    func testRecordingAdoptionRequiresLiveScreencapture() {
        let record = RecordingState(pid: 42, startedAt: 1_000, path: "/tmp/rec.mov")

        XCTAssertEqual(
            CaptureService.decideAdoption(record: record, pidAlive: false, executablePath: "/usr/sbin/screencapture"),
            .cleanedUp(reason: "pid 42 is gone")
        )
        XCTAssertEqual(
            CaptureService.decideAdoption(record: record, pidAlive: true, executablePath: "/bin/bash"),
            .cleanedUp(reason: "pid 42 is /bin/bash, not screencapture")
        )
        XCTAssertEqual(
            CaptureService.decideAdoption(record: record, pidAlive: true, executablePath: "/usr/sbin/screencapture"),
            .adopted(path: "/tmp/rec.mov", startedAt: Date(timeIntervalSince1970: 1_000))
        )
    }

    @MainActor
    func testAdoptsRealLiveProcessAndQuitStopsIt() throws {
        let (_, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        // /bin/sleep stands in for screencapture so the test needs no Screen
        // Recording permission; proc_pidpath checks the real executable.
        let fake = root.appendingPathComponent("fake-screencapture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let process = Process()
        process.executableURL = fake
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let stateFile = root.appendingPathComponent("recording.json")
        let record = RecordingState(
            pid: process.processIdentifier,
            startedAt: Date().timeIntervalSince1970 - 5,
            path: root.appendingPathComponent("rec.mov").path
        )
        try JSONEncoder().encode(record).write(to: stateFile)

        let service = CaptureService()
        service.stateFile = stateFile
        service.toolPath = fake.path
        guard case .adopted = service.adoptPendingRecording() else {
            return XCTFail("a live matching pid must be adopted")
        }
        XCTAssertTrue(service.isRecording)
        XCTAssertGreaterThan(service.recordingElapsed, 4)

        service.stopRecordingOnQuit()
        XCTAssertFalse(CaptureService.isAlive(process.processIdentifier), "quit stops the recorder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path), "state file is removed")
    }

    @MainActor
    func testCleansUpWhenPidIsAnotherProgram() throws {
        let (_, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let stateFile = root.appendingPathComponent("recording.json")
        let record = RecordingState(pid: process.processIdentifier, startedAt: 0, path: "/tmp/rec.mov")
        try JSONEncoder().encode(record).write(to: stateFile)

        let service = CaptureService()
        service.stateFile = stateFile
        guard case .cleanedUp = service.adoptPendingRecording() else {
            return XCTFail("a pid that is not screencapture must not be adopted")
        }
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
    }
}
