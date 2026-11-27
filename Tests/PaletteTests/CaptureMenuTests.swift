import Foundation
import XCTest
@testable import PaletteCore

/// The status-menu capture section is pure state, so its enable/disable rules
/// are pinned without opening a menu.
final class CaptureMenuTests: XCTestCase {
    private func state(
        recording: Bool = false,
        elapsed: TimeInterval = 0,
        last: String? = nil,
        lastRecording: String? = nil,
        lastScreenshot: String? = nil
    ) -> [CaptureMenuCommand: CaptureMenuItemState] {
        let items = CaptureMenu.items(
            isRecording: recording,
            elapsed: elapsed,
            lastCapturePath: last,
            lastRecordingPath: lastRecording,
            lastScreenshotPath: lastScreenshot
        )
        return Dictionary(uniqueKeysWithValues: items.map { ($0.command, $0) })
    }

    func testIdleWithoutCapturesOnlyStarts() throws {
        let items = state()
        XCTAssertEqual(items[.startRecording]?.enabled, true)
        XCTAssertEqual(items[.startRecording]?.visible, true)
        XCTAssertEqual(items[.stopRecording]?.enabled, false)
        XCTAssertEqual(items[.stopRecording]?.visible, false)
        XCTAssertEqual(items[.stopRecording]?.title, "Stop Recording · 0:00")
        XCTAssertEqual(items[.copyLastPath]?.enabled, false)
        XCTAssertEqual(items[.revealLastCapture]?.enabled, false)
        XCTAssertEqual(items[.showLastRecording]?.visible, false)
        XCTAssertEqual(items[.showLastScreenshot]?.visible, false)
        XCTAssertEqual(items[.pinLastScreenshot]?.visible, false)
        XCTAssertEqual(items[.copyTextFromLastScreenshot]?.visible, false)
        XCTAssertEqual(items[.openLastScreenshotLink]?.visible, false)
    }

    func testRecordingDisablesStartAndShowsElapsed() throws {
        let items = state(recording: true, elapsed: 65)
        XCTAssertEqual(items[.startRecording]?.enabled, false)
        XCTAssertEqual(items[.startRecording]?.visible, false)
        XCTAssertEqual(items[.stopRecording]?.visible, true)
        XCTAssertEqual(items[.stopRecording]?.enabled, true)
        XCTAssertEqual(items[.stopRecording]?.visible, true)
        XCTAssertEqual(items[.stopRecording]?.title, "Stop Recording · 1:05")
    }

    func testCapturesEnableCopyAndReveal() throws {
        let items = state(last: "/tmp/rec.mov")
        XCTAssertEqual(items[.copyLastPath]?.enabled, true)
        XCTAssertEqual(items[.revealLastCapture]?.enabled, true)
    }

    func testShowRowsAppearOnlyForTheKindThatExists() throws {
        let recordingOnly = state(last: "/tmp/rec.mov", lastRecording: "/tmp/rec.mov")
        XCTAssertEqual(recordingOnly[.showLastRecording]?.visible, true)
        XCTAssertEqual(recordingOnly[.showLastScreenshot]?.visible, false)

        let screenshotOnly = state(last: "/tmp/shot.png", lastScreenshot: "/tmp/shot.png")
        XCTAssertEqual(screenshotOnly[.showLastRecording]?.visible, false)
        XCTAssertEqual(screenshotOnly[.showLastScreenshot]?.visible, true)
        XCTAssertEqual(screenshotOnly[.pinLastScreenshot]?.visible, true)
        XCTAssertEqual(screenshotOnly[.pinLastScreenshot]?.title, "Pin Last Screenshot")
        XCTAssertEqual(screenshotOnly[.copyTextFromLastScreenshot]?.visible, true)
        XCTAssertEqual(screenshotOnly[.openLastScreenshotLink]?.visible, true)

        let recordingOnlyForOCR = state(last: "/tmp/rec.mov", lastRecording: "/tmp/rec.mov", lastScreenshot: "/tmp/shot.png")
        XCTAssertEqual(recordingOnlyForOCR[.copyTextFromLastScreenshot]?.visible, true)
        XCTAssertEqual(recordingOnlyForOCR[.openLastScreenshotLink]?.visible, true)
    }
}
