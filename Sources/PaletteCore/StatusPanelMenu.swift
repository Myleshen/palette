import CoreGraphics
import Foundation

/// Every action the status panel can run. The app maps each case onto the same
/// method its old menu item called, so the panel holds no business logic.
public enum StatusPanelCommand: Hashable, Sendable {
    case capture(CaptureMenuCommand)
    case openPalette
    case updatePalette
    case releaseNotes
    case reloadConfig
    case setPosition(SearchPosition)
    case toggleClamshell
    case stopKeepAwake
    case startKeepAwake(TimeInterval?)
    case refreshBitwarden
    case settings
    case openConfig
    case openLog
    case openProviders
    case openThemes
    case exportBackup
    case quit
}

/// One row: a label, whether it applies now, and the check/shortcut hint the
/// row draws on its right. Pure so the rules are testable without AppKit.
public struct StatusPanelRow: Equatable, Sendable, Identifiable {
    public var command: StatusPanelCommand
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    /// Shown right-aligned, e.g. "⌘R".
    public var keyHint: String?

    public var id: StatusPanelCommand { command }

    public init(
        command: StatusPanelCommand,
        title: String,
        enabled: Bool = true,
        checked: Bool = false,
        keyHint: String? = nil
    ) {
        self.command = command
        self.title = title
        self.enabled = enabled
        self.checked = checked
        self.keyHint = keyHint
    }
}

/// A group of rows, optionally titled and with one line of live state under it
/// (the keep-awake session). Rows are already filtered to what is visible.
public struct StatusPanelSection: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var detail: String?
    public var rows: [StatusPanelRow]

    public init(id: String, title: String? = nil, detail: String? = nil, rows: [StatusPanelRow]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.rows = rows
    }
}

/// The live facts a panel render reads. A plain value so a test can build one
/// without capture, sleep or theme services.
public struct StatusPanelSnapshot: Equatable, Sendable {
    public var isRecording: Bool
    public var recordingElapsed: TimeInterval
    public var lastCapturePath: String?
    public var lastRecordingPath: String?
    public var lastScreenshotPath: String?
    public var launcherPosition: SearchPosition
    public var keepAwakeActive: Bool
    public var keepAwakeRemaining: String?
    public var keepAwakeClamshell: Bool
    public var keepAwakeClamshellRequiresPower: Bool
    public var updateVersion: String?

    public init(
        isRecording: Bool = false,
        recordingElapsed: TimeInterval = 0,
        lastCapturePath: String? = nil,
        lastRecordingPath: String? = nil,
        lastScreenshotPath: String? = nil,
        launcherPosition: SearchPosition = .top,
        keepAwakeActive: Bool = false,
        keepAwakeRemaining: String? = nil,
        keepAwakeClamshell: Bool = false,
        keepAwakeClamshellRequiresPower: Bool = false,
        updateVersion: String? = nil
    ) {
        self.isRecording = isRecording
        self.recordingElapsed = recordingElapsed
        self.lastCapturePath = lastCapturePath
        self.lastRecordingPath = lastRecordingPath
        self.lastScreenshotPath = lastScreenshotPath
        self.launcherPosition = launcherPosition
        self.keepAwakeActive = keepAwakeActive
        self.keepAwakeRemaining = keepAwakeRemaining
        self.keepAwakeClamshell = keepAwakeClamshell
        self.keepAwakeClamshellRequiresPower = keepAwakeClamshellRequiresPower
        self.updateVersion = updateVersion
    }
}

/// The panel's sections and their enable/visible rules. `CaptureMenu` stays the
/// single source for the capture rows; this adds the rest around them.
public enum StatusPanelMenu {
    public static let keepAwakeChoices: [(seconds: TimeInterval?, title: String)] = [
        (15 * 60, "For 15 Minutes"),
        (30 * 60, "For 30 Minutes"),
        (60 * 60, "For 1 Hour"),
        (2 * 60 * 60, "For 2 Hours"),
        (4 * 60 * 60, "For 4 Hours"),
        (8 * 60 * 60, "For 8 Hours"),
        (nil, "Indefinitely"),
    ]

    public static func sections(_ snapshot: StatusPanelSnapshot) -> [StatusPanelSection] {
        var sections: [StatusPanelSection] = []

        let capture = CaptureMenu.items(
            isRecording: snapshot.isRecording,
            elapsed: snapshot.recordingElapsed,
            lastCapturePath: snapshot.lastCapturePath,
            lastRecordingPath: snapshot.lastRecordingPath,
            lastScreenshotPath: snapshot.lastScreenshotPath
        )
        .filter(\.visible)
        .map {
            StatusPanelRow(
                command: .capture($0.command),
                title: $0.title,
                enabled: $0.enabled
            )
        }
        if !capture.isEmpty {
            sections.append(StatusPanelSection(id: "capture", title: "Capture", rows: capture))
        }

        var palette = [
            StatusPanelRow(command: .openPalette, title: "Open Palette"),
            StatusPanelRow(command: .reloadConfig, title: "Reload Configuration", keyHint: "⌘R"),
        ]
        if let version = snapshot.updateVersion {
            palette.append(
                StatusPanelRow(
                    command: .updatePalette,
                    title: "Palette \(version) available — Update…"
                )
            )
            palette.append(StatusPanelRow(command: .releaseNotes, title: "Release notes"))
        }
        sections.append(StatusPanelSection(id: "palette", title: "Palette", rows: palette))

        sections.append(
            StatusPanelSection(
                id: "position",
                title: "Launcher Position",
                rows: SearchPosition.allCases.map { position in
                    StatusPanelRow(
                        command: .setPosition(position),
                        title: position.rawValue.capitalized,
                        checked: snapshot.launcherPosition == position
                    )
                }
            )
        )

        var keepAwake: [StatusPanelRow] = []
        keepAwake.append(
            StatusPanelRow(
                command: .toggleClamshell,
                title: snapshot.keepAwakeClamshell && snapshot.keepAwakeClamshellRequiresPower
                    ? "Clamshell (Lid Closed) — armed, inactive"
                    : "Clamshell (Lid Closed)",
                checked: snapshot.keepAwakeClamshell
            )
        )
        keepAwake.append(
            StatusPanelRow(
                command: .stopKeepAwake,
                title: "Stop Keeping Awake",
                enabled: snapshot.keepAwakeActive
            )
        )
        for choice in keepAwakeChoices {
            keepAwake.append(
                StatusPanelRow(
                    command: .startKeepAwake(choice.seconds),
                    title: choice.title
                )
            )
        }
        sections.append(
            StatusPanelSection(
                id: "keepAwake",
                title: "Keep Awake",
                detail: keepAwakeDetail(snapshot),
                rows: keepAwake
            )
        )

        sections.append(
            StatusPanelSection(
                id: "bitwarden",
                rows: [StatusPanelRow(command: .refreshBitwarden, title: "Refresh Bitwarden Cache")]
            )
        )
        sections.append(
            StatusPanelSection(
                id: "settings",
                rows: [StatusPanelRow(command: .settings, title: "Settings…")]
            )
        )
        sections.append(
            StatusPanelSection(
                id: "advanced",
                title: "Advanced",
                rows: [
                    StatusPanelRow(command: .openConfig, title: "Open config.toml"),
                    StatusPanelRow(command: .openLog, title: "Open Log"),
                    StatusPanelRow(command: .openProviders, title: "Open Providers Folder"),
                    StatusPanelRow(command: .openThemes, title: "Open Themes Folder"),
                    StatusPanelRow(command: .exportBackup, title: "Export Backup…"),
                ]
            )
        )
        sections.append(
            StatusPanelSection(
                id: "quit",
                rows: [StatusPanelRow(command: .quit, title: "Quit Palette", keyHint: "⌘Q")]
            )
        )
        return sections
    }

    /// The one line under "Keep Awake": the live session, or that sleep is on.
    public static func keepAwakeDetail(_ snapshot: StatusPanelSnapshot) -> String {
        guard snapshot.keepAwakeActive else { return "Not keeping awake" }
        if let remaining = snapshot.keepAwakeRemaining, !remaining.isEmpty {
            return "Awake · \(remaining) left"
        }
        return "Awake · indefinitely"
    }
}

/// Where the panel sits under the status button. Pure so clamping is testable
/// without a screen.
public enum StatusPanelLayout {
    public static let width: CGFloat = 300
    /// Breathing room between the button and the panel.
    public static let gap: CGFloat = 6
    /// Breathing room between the panel and the screen edge.
    public static let margin: CGFloat = 8

    /// `anchor` is the status button in screen coordinates, `screen` the
    /// visible frame. The panel hangs right-aligned under the button and never
    /// leaves the screen; a screen too short for the content caps the height so
    /// the content scrolls instead.
    public static func frame(anchor: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let bounds = screen.insetBy(dx: margin, dy: margin)
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x = min(
            max(anchor.maxX - width, bounds.minX),
            max(bounds.minX, bounds.maxX - width)
        )
        let y = min(
            max(anchor.minY - gap - height, bounds.minY),
            max(bounds.minY, bounds.maxY - height)
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
