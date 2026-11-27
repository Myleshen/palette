import Foundation
import XCTest
@testable import PaletteCore
@testable import PalettePlatform

/// The recording options are pure arguments to `screencapture -v`; this pins
/// them without needing Screen Recording permission to actually capture.
final class RecordingArgumentsTests: XCTestCase {
    private let path = "/tmp/rec.mov"

    func testConfigMapsToScreencaptureFlags() {
        var screen = CaptureConfig()
        screen.recordingTarget = "screen"
        XCTAssertEqual(CaptureService.recordingArguments(config: screen, path: path), ["-v", path])

        var display = CaptureConfig()
        display.recordingTarget = "display"
        display.recordingDisplay = 2
        XCTAssertEqual(
            CaptureService.recordingArguments(config: display, path: path),
            ["-v", "-D", "2", path]
        )
        display.recordingDisplay = 0
        XCTAssertEqual(
            CaptureService.recordingArguments(config: display, path: path),
            ["-v", "-D", "1", path],
            "the display index is one-based"
        )

        var region = CaptureConfig()
        region.recordingTarget = "region"
        region.recordingRegion = "10,20,300,400"
        XCTAssertEqual(
            CaptureService.recordingArguments(config: region, path: path),
            ["-v", "-R", "10,20,300,400", path]
        )
        region.recordingRegion = "   "
        XCTAssertEqual(
            CaptureService.recordingArguments(config: region, path: path),
            ["-v", path],
            "an empty region falls back to the whole screen"
        )

        var extras = CaptureConfig()
        extras.recordingAudio = true
        extras.captureCursor = true
        extras.showClicks = true
        XCTAssertEqual(
            CaptureService.recordingArguments(config: extras, path: path),
            ["-v", "-g", "-C", "-k", path]
        )

        extras.recordingMicrophone = "  BuiltInMicrophoneDevice  "
        let mic = CaptureService.recordingArguments(config: extras, path: path)
        XCTAssertEqual(mic, ["-v", "-G", "BuiltInMicrophoneDevice", "-C", "-k", path])
        XCTAssertFalse(mic.contains("-g"), "a chosen microphone replaces the default")
        extras.recordingMicrophone = "   "
        XCTAssertEqual(
            CaptureService.recordingArguments(config: extras, path: path),
            ["-v", "-g", "-C", "-k", path]
        )
    }

    // MARK: - The per-recording options panel

    func testOptionsMapToTheSameArgumentBuilder() {
        let display = RecordingOptions(
            audio: true,
            microphone: "BuiltInMicrophoneDevice",
            target: .display,
            display: 2
        )
        XCTAssertEqual(
            display.recordingArguments(path: path),
            ["-v", "-D", "2", "-G", "BuiltInMicrophoneDevice", path]
        )

        let region = RecordingOptions(target: .region, region: "10,20,300,400")
        XCTAssertEqual(region.recordingArguments(path: path), ["-v", "-R", "10,20,300,400", path])

        let muted = RecordingOptions(audio: false, microphone: "BuiltInMicrophoneDevice", target: .screen)
        XCTAssertEqual(muted.recordingArguments(path: path), ["-v", path])
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
