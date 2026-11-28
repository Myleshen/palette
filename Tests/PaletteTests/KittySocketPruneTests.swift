import XCTest
@testable import PalettePlatform

final class KittySocketPruneTests: XCTestCase {
    func testDeadSocketsAreRemovedAndLiveOnesKept() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-sockets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("palette-kitty-4242")
        let dead = dir.appendingPathComponent("palette-kitty-9999")
        let foreign = dir.appendingPathComponent("some-other-socket")
        for url in [live, dead, foreign] { FileManager.default.createFile(atPath: url.path, contents: Data()) }

        KittyRemoteControl.pruneStaleSockets(pids: [4242], directories: [dir.path])

        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "not ours, leave it")
    }
}
