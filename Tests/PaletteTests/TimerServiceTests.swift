import XCTest
import Foundation
import PalettePlatform

@MainActor
final class TimerServiceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-timer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: URL { directory.appendingPathComponent("timer.json") }

    private func writeState(id: String, endsAt: Date, total: Double, label: String) throws {
        let payload: [String: Any] = [
            "id": id,
            "endsAt": endsAt.timeIntervalSince1970,
            "total": total,
            "label": label,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: stateFile)
    }

    func testStartPersistsDeadlineAndStopClearsIt() throws {
        let service = TimerService()
        service.configure(sound: false, notifications: false)
        service.adopt(stateDir: directory)

        service.start(seconds: 60, label: "1m")

        let data = try Data(contentsOf: stateFile)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(stored["label"] as? String, "1m")
        XCTAssertEqual(stored["total"] as? Double, 60)
        let endsAt = try XCTUnwrap(stored["endsAt"] as? Double)
        XCTAssertEqual(endsAt, Date().addingTimeInterval(60).timeIntervalSince1970, accuracy: 2)
        XCTAssertFalse((stored["id"] as? String ?? "").isEmpty)

        service.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
        XCTAssertFalse(service.snapshot().isRunning)
    }

    func testAdoptRestoresAFutureTimer() throws {
        try writeState(id: "abc", endsAt: Date().addingTimeInterval(120), total: 180, label: "3m")
        let service = TimerService()
        service.configure(sound: false, notifications: false)

        XCTAssertEqual(service.adopt(stateDir: directory), .running)
        let snapshot = service.snapshot()
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertEqual(snapshot.label, "3m")
        XCTAssertEqual(snapshot.total, 180)
        XCTAssertGreaterThan(snapshot.remaining, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))
        service.stop()
    }

    func testAdoptAnnouncesAnExpiredTimerAndClearsIt() throws {
        try writeState(id: "abc", endsAt: Date().addingTimeInterval(-30), total: 60, label: "1m")
        let service = TimerService()
        service.configure(sound: false, notifications: false)

        XCTAssertEqual(service.adopt(stateDir: directory), .expired(label: "1m"))
        XCTAssertFalse(service.snapshot().isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
        // A second launch has nothing left to announce.
        XCTAssertNil(service.adopt(stateDir: directory))
    }

    func testAdoptIgnoresACorruptFile() throws {
        try Data("not json".utf8).write(to: stateFile)
        let service = TimerService()
        service.configure(sound: false, notifications: false)
        XCTAssertNil(service.adopt(stateDir: directory))
        XCTAssertFalse(service.snapshot().isRunning)
    }
}
