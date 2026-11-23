import AVKit
import AppKit
import PaletteCore
import PalettePlatform
import SwiftUI

/// Preview for a finished recording: play it, reveal it, or copy its path.
@MainActor
final class MediaPreviewWindowController: NSWindowController, NSWindowDelegate {
    static let frameAutosaveName = "PaletteMediaPreview"

    private let player: AVPlayer
    var onClose: (() -> Void)?
    /// Buttons in the preview report through the same visible feedback as the
    /// menu bar, instead of silently doing their work.
    var onFeedback: ((String) -> Void)?

    init(url: URL, themeManager: ThemeManager) {
        player = AVPlayer(url: url)
        let theme = themeManager.theme
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        // A preview must survive switching apps; it used to vanish and take the
        // only route to the recording with it.
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilitySubrole(.dialog)
        window.title = url.lastPathComponent
        window.appearance = theme.nsAppearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = theme.nsColor(theme.palette.bg)
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MediaPreviewView(
            player: player,
            url: url,
            themeManager: themeManager,
            feedback: { [weak self] message in self?.onFeedback?(message) },
            close: { [weak self] in
                self?.player.pause()
                self?.close()
            }
        ))
        // One remembered spot instead of a new recording stacking exactly on
        // the last one.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The player area stays black; only the window chrome follows the theme.
    func apply(theme: Theme) {
        window?.appearance = theme.nsAppearance
        window?.backgroundColor = theme.nsColor(theme.palette.bg)
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        onClose?()
    }

    func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        player.play()
    }
}

private struct MediaPreviewView: View {
    let player: AVPlayer
    let url: URL
    @ObservedObject var themeManager: ThemeManager
    var feedback: (String) -> Void
    var close: () -> Void

    private var theme: Theme { themeManager.theme }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .background(Color.black)
            Divider()
            HStack(spacing: 10) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color(theme.palette.fgMuted))
                    .lineLimit(1)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    feedback("Revealed in Finder")
                }
                Button("Copy Path") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url.path, forType: .string)
                    ClipboardMonitor.notePaletteWrite(pasteboard.changeCount)
                    feedback("Path copied")
                }
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(PillButton(theme: theme))
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background {
                ZStack {
                    theme.color(theme.palette.bg)
                    GlassSurface(shape: Rectangle(), tint: theme.color(theme.palette.elevated).opacity(0.55))
                }
            }
        }
        .onDisappear { player.pause() }
    }
}
