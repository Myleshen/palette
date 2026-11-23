import Foundation
import XCTest
@testable import PaletteCore
@testable import PalettePlatform

/// The recording options are pure arguments to `screencapture -v`; this pins
/// them without needing Screen Recording permission to actually capture.
final class RecordingArgumentsTests: XCTestCase {
    private let path = "/tmp/rec.mov"

    func testWholeScreenHasNoTargetFlags() {
        var config = CaptureConfig()
        config.recordingTarget = "screen"
        XCTAssertEqual(CaptureService.recordingArguments(config: config, path: path), ["-v", path])
    }

    func testDisplayTargetPassesOneBasedIndex() {
        var config = CaptureConfig()
        config.recordingTarget = "display"
        config.recordingDisplay = 2
        XCTAssertEqual(
            CaptureService.recordingArguments(config: config, path: path),
            ["-v", "-D", "2", path]
        )
    }

    func testDisplayIndexIsAtLeastOne() {
        var config = CaptureConfig()
        config.recordingTarget = "display"
        config.recordingDisplay = 0
        XCTAssertEqual(
            CaptureService.recordingArguments(config: config, path: path),
            ["-v", "-D", "1", path]
        )
    }

    func testRegionTargetUsesTheConfiguredRectangle() {
        var config = CaptureConfig()
        config.recordingTarget = "region"
        config.recordingRegion = "10,20,300,400"
        XCTAssertEqual(
            CaptureService.recordingArguments(config: config, path: path),
            ["-v", "-R", "10,20,300,400", path]
        )
    }

    func testEmptyRegionFallsBackToTheWholeScreen() {
        var config = CaptureConfig()
        config.recordingTarget = "region"
        config.recordingRegion = "   "
        XCTAssertEqual(CaptureService.recordingArguments(config: config, path: path), ["-v", path])
    }

    func testAudioCursorAndClicksAddTheirFlags() {
        var config = CaptureConfig()
        config.recordingAudio = true
        config.captureCursor = true
        config.showClicks = true
        XCTAssertEqual(
            CaptureService.recordingArguments(config: config, path: path),
            ["-v", "-g", "-C", "-k", path]
        )
    }

    func testConfiguredMicrophoneUsesTheGFlagAndNotTheDefault() {
        var config = CaptureConfig()
        config.recordingAudio = true
        config.recordingMicrophone = "  BuiltInMicrophoneDevice  "
        let arguments = CaptureService.recordingArguments(config: config, path: path)
        XCTAssertEqual(arguments, ["-v", "-G", "BuiltInMicrophoneDevice", path])
        XCTAssertFalse(arguments.contains("-g"))
    }

    func testEmptyMicrophoneFallsBackToTheSystemDefault() {
        var config = CaptureConfig()
        config.recordingAudio = true
        config.recordingMicrophone = "   "
        XCTAssertEqual(CaptureService.recordingArguments(config: config, path: path), ["-v", "-g", path])
    }

    // MARK: - The per-recording options panel

    func testOptionsMapToTheSameArgumentBuilder() {
        let options = RecordingOptions(
            audio: true,
            microphone: "BuiltInMicrophoneDevice",
            target: .display,
            display: 2
        )
        XCTAssertEqual(
            options.recordingArguments(path: path),
            ["-v", "-D", "2", "-G", "BuiltInMicrophoneDevice", path]
        )
    }

    func testAudioOffDropsTheMicrophoneFlag() {
        let options = RecordingOptions(
            audio: false,
            microphone: "BuiltInMicrophoneDevice",
            target: .screen
        )
        XCTAssertEqual(options.recordingArguments(path: path), ["-v", path])
    }

    func testSelectionUsesTheTypedRegion() {
        let options = RecordingOptions(target: .region, region: "10,20,300,400")
        XCTAssertEqual(
            options.recordingArguments(path: path),
            ["-v", "-R", "10,20,300,400", path]
        )
    }

    func testOptionsFromTheConfigAreRememberedAndRoundTrip() {
        var config = CaptureConfig()
        config.recordingAudio = true
        config.recordingMicrophone = "USB Mic"
        config.recordingTarget = "display"
        config.recordingDisplay = 3

        var options = RecordingOptions(capture: config)
        XCTAssertEqual(options.audio, true)
        XCTAssertEqual(options.microphone, "USB Mic")
        XCTAssertEqual(options.target, .display)
        XCTAssertEqual(options.display, 3)

        options.audio = false
        options.target = .region
        options.region = "5,5,100,100"
        options.apply(to: &config)
        XCTAssertEqual(config.recordingAudio, false)
        XCTAssertEqual(config.recordingTarget, "region")
        XCTAssertEqual(config.recordingRegion, "5,5,100,100")
        XCTAssertEqual(config.recordingDisplay, 3, "an unchanged picker keeps its value")
    }
}
