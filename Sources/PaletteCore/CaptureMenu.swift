import Foundation

/// Menu-bar capture commands, in the order the status menu lists them.
public enum CaptureMenuCommand: String, CaseIterable, Sendable {
    case startRecording
    case stopRecording
    case copyLastPath
    case revealLastCapture
    case showLastRecording
    case showLastScreenshot
    case pinLastScreenshot
    case copyTextFromLastScreenshot
    case openLastScreenshotLink
}

/// One row of the capture section: what it says and whether it applies now.
public struct CaptureMenuItemState: Equatable, Sendable {
    public var command: CaptureMenuCommand
    public var title: String
    public var enabled: Bool
    /// The "Show Last …" rows only exist while there is a capture of that kind.
    public var visible: Bool

    public init(command: CaptureMenuCommand, title: String, enabled: Bool, visible: Bool) {
        self.command = command
        self.title = title
        self.enabled = enabled
        self.visible = visible
    }
}

/// Pure menu state so enable/disable rules are testable without AppKit.
public enum CaptureMenu {
    public static func items(
        isRecording: Bool,
        elapsed: TimeInterval,
        lastCapturePath: String?,
        lastRecordingPath: String?,
        lastScreenshotPath: String?
    ) -> [CaptureMenuItemState] {
        let hasCapture = !(lastCapturePath ?? "").isEmpty
        return [
            CaptureMenuItemState(
                command: .startRecording,
                title: "Start Recording…",
                enabled: !isRecording,
                visible: true
            ),
            CaptureMenuItemState(
                command: .stopRecording,
                title: isRecording
                    ? "Stop Recording · \(TimerDuration.format(elapsed))"
                    : "Stop Recording",
                enabled: isRecording,
                visible: true
            ),
            CaptureMenuItemState(
                command: .copyLastPath,
                title: "Copy Last Path",
                enabled: hasCapture,
                visible: true
            ),
            CaptureMenuItemState(
                command: .revealLastCapture,
                title: "Reveal Last Capture",
                enabled: hasCapture,
                visible: true
            ),
            CaptureMenuItemState(
                command: .showLastRecording,
                title: "Show Last Recording",
                enabled: true,
                visible: !(lastRecordingPath ?? "").isEmpty
            ),
            CaptureMenuItemState(
                command: .showLastScreenshot,
                title: "Show Last Screenshot",
                enabled: true,
                visible: !(lastScreenshotPath ?? "").isEmpty
            ),
            CaptureMenuItemState(
                command: .pinLastScreenshot,
                title: "Pin Last Screenshot",
                enabled: true,
                visible: !(lastScreenshotPath ?? "").isEmpty
            ),
            CaptureMenuItemState(
                command: .copyTextFromLastScreenshot,
                title: "Copy Text from Last Screenshot",
                enabled: true,
                visible: !(lastScreenshotPath ?? "").isEmpty
            ),
            CaptureMenuItemState(
                command: .openLastScreenshotLink,
                title: "Open Detected Link",
                enabled: true,
                visible: !(lastScreenshotPath ?? "").isEmpty
            ),
        ]
    }
}
