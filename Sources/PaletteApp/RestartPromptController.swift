import AppKit
import PaletteCore
import PalettePlatform
import SwiftUI

/// A themed, non-activating prompt that never starts a tracking loop. Esc picks
/// the secondary action; a click outside dismisses it the same way.
@MainActor
final class RestartPromptController: NSWindowController {
    private let themeManager: ThemeManager
    private let onRestart: () -> Void
    private let onLater: () -> Void
    private var prompt: RestartPrompt?
    private var clickMonitors: [Any] = []

    private static let width: CGFloat = 420

    init(
        themeManager: ThemeManager,
        onRestart: @escaping () -> Void,
        onLater: @escaping () -> Void
    ) {
        self.themeManager = themeManager
        self.onRestart = onRestart
        self.onLater = onLater
        let panel = RestartPromptWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ prompt: RestartPrompt) {
        guard let window, !prompt.apps.isEmpty else { return }
        self.prompt = prompt
        let view = RestartPromptView(
            prompt: prompt,
            themeManager: themeManager,
            restart: { [weak self] in self?.restart() },
            later: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: Self.width, height: max(1, hosting.fittingSize.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.contentView = hosting
        window.appearance = themeManager.theme.nsAppearance
        window.title = prompt.title
        window.setContentSize(size)
        centre(window, size: size)
        installClickMonitors()
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(nil)
    }

    func hide() {
        prompt = nil
        removeClickMonitors()
        window?.orderOut(nil)
    }

    private func centre(_ window: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }

    // MARK: - Dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, event.window !== self.window else { return event }
            self.dismiss()
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        if let local { clickMonitors.append(local) }
        if let global { clickMonitors.append(global) }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }

    private func restart() {
        hide()
        onRestart()
    }

    private func dismiss() {
        hide()
        onLater()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            dismiss()
            return true
        case 36, 76: // Return, keypad Enter
            restart()
            return true
        default:
            return false
        }
    }
}

/// Takes key events for Return and Esc without becoming the main window.
private final class RestartPromptWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

private struct RestartPromptView: View {
    let prompt: RestartPrompt
    @ObservedObject var themeManager: ThemeManager
    var restart: () -> Void
    var later: () -> Void

    private var theme: Theme { themeManager.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.color(theme.palette.fg))
            Text(prompt.message)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.color(theme.palette.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: later) {
                    Text(prompt.secondaryLabel)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.color(theme.palette.fg))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(prompt.secondaryLabel))
                .accessibilityAddTraits(.isButton)

                Button(action: restart) {
                    Text(prompt.primaryLabel)
                        .font(theme.font(size: 12).weight(.semibold))
                        .foregroundStyle(theme.color(theme.palette.bg))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.color(theme.palette.accent))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(prompt.primaryLabel))
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.color(theme.palette.bg))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.color(theme.palette.border), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(prompt.title))
    }
}
