import PaletteCore

/// What the recording hotkey asks for each time. It maps onto `CaptureConfig`
/// (so the next press remembers the choice) and onto the `screencapture -v`
/// arguments the service already builds.
public struct RecordingOptions: Equatable, Sendable {
    public enum Target: String, CaseIterable, Sendable {
        case screen
        case display
        case region
    }

    public var audio: Bool
    public var microphone: String
    public var target: Target
    public var display: Int
    public var region: String

    public init(capture: CaptureConfig) {
        audio = capture.recordingAudio
        microphone = capture.recordingMicrophone
        target = Target(rawValue: capture.recordingTarget) ?? .screen
        display = max(1, capture.recordingDisplay)
        region = capture.recordingRegion
    }

    public init(
        audio: Bool = false,
        microphone: String = "",
        target: Target = .screen,
        display: Int = 1,
        region: String = ""
    ) {
        self.audio = audio
        self.microphone = microphone
        self.target = target
        self.display = max(1, display)
        self.region = region
    }

    public func apply(to capture: inout CaptureConfig) {
        capture.recordingAudio = audio
        capture.recordingMicrophone = microphone
        capture.recordingTarget = target.rawValue
        capture.recordingDisplay = max(1, display)
        capture.recordingRegion = region
    }

    /// The arguments these options alone produce, for the panel's preview and
    /// for tests; the real start applies them to the live config first.
    public func recordingArguments(path: String) -> [String] {
        var capture = CaptureConfig()
        apply(to: &capture)
        return CaptureService.recordingArguments(config: capture, path: path)
    }
}
