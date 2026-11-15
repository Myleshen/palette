import AVKit
import AppKit
import SwiftUI

/// Preview for a finished recording: play it, reveal it, or copy its path.
@MainActor
final class MediaPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let player: AVPlayer
    var onClose: (() -> Void)?

    init(url: URL) {
        player = AVPlayer(url: url)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilitySubrole(.dialog)
        window.title = url.lastPathComponent
        // The app runs a dark theme; without this the stock buttons draw white
        // text on a white bezel.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MediaPreviewView(player: player, url: url, close: { [weak self] in
            self?.player.pause()
            self?.close()
        }))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        onClose?()
        restoreAccessoryPolicyIfIdle()
    }

    func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }
}

private struct MediaPreviewView: View {
    let player: AVPlayer
    let url: URL
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .background(Color.black)
            Divider()
            HStack(spacing: 10) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(PillButton())
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(white: 0.12))
        }
        .onDisappear { player.pause() }
    }
}
