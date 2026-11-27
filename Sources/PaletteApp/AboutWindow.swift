import AppKit
import PaletteCore
import PalettePlatform
import SwiftUI

/// Facts shared by the About window and the Settings card. Read from the built
/// bundle so a release build reports what actually shipped.
struct AboutInfo {
    static let author = "Myleshen"
    static let email = "contact@myleshenp.dev"
    static let repo = URL(string: "https://github.com/Myleshen/palette")!
    static let releases = URL(string: "https://github.com/Myleshen/palette/releases")!
    static let issues = URL(string: "https://github.com/Myleshen/palette/issues")!
    static let licence = URL(string: "https://github.com/Myleshen/palette/blob/main/LICENSE")!

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var versionBuild: String { "\(version) (\(build))" }

    var commit: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "PaletteCommit") as? String
        return value?.isEmpty == false ? value : nil
    }

    static var macOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return osBuild.isEmpty ? short : "\(short) (\(osBuild))"
    }

    static let chip: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()

    static var diagnostics: String {
        var lines = ["Palette \(AboutInfo().versionBuild)"]
        if let commit = AboutInfo().commit { lines.append("Commit: \(commit)") }
        lines.append("macOS: \(macOS)")
        lines.append("Chip: \(chip)")
        return lines.joined(separator: "\n")
    }

    static func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    /// The bundle's .icns keeps every size; the window renders whichever
    /// representation fits its 88-point frame. Loaded once, not per body pass.
    static let icon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    }()

    private static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}

struct AboutView: View {
    @ObservedObject var themeManager: ThemeManager
    var close: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var copied = false

    private var theme: Theme { themeManager.theme }
    private var muted: Color { theme.color(theme.palette.fgMuted) }
    private var info: AboutInfo { AboutInfo() }

    var body: some View {
        VStack(spacing: 8) {
            if let icon = AboutInfo.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
            }

            Text("Palette")
                .font(theme.font(size: 22, weight: .semibold))
                .foregroundStyle(theme.color(theme.palette.fg))

            VStack(spacing: 2) {
                Text("Version \(info.versionBuild)")
                if let commit = info.commit {
                    Text("Commit \(commit)")
                }
            }
            .font(theme.font(size: 11))
            .foregroundStyle(muted)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Built by ")
                    Text(AboutInfo.author).fontWeight(.semibold)
                }
                Link(AboutInfo.email, destination: URL(string: "mailto:\(AboutInfo.email)")!)
                    .foregroundStyle(theme.color(theme.palette.accent))
            }
            .font(theme.font(size: 12))
            .padding(.top, 2)

            VStack(spacing: 2) {
                Text("A keyboard-first launcher for macOS.")
                Text("MIT licensed · Built with SwiftUI + AppKit.")
                    .foregroundStyle(muted)
            }
            .font(theme.font(size: 12))
            .multilineTextAlignment(.center)
            .padding(.top, 2)

            HStack(spacing: 8) {
                linkButton("GitHub", AboutInfo.repo)
                linkButton("Releases", AboutInfo.releases)
                linkButton("Report an Issue", AboutInfo.issues)
            }
            .padding(.top, 6)

            HStack(spacing: 4) {
                Text("Licence:")
                    .foregroundStyle(muted)
                Link("MIT", destination: AboutInfo.licence)
                    .foregroundStyle(theme.color(theme.palette.accent))
            }
            .font(theme.font(size: 10))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Diagnostics") {
                    AboutInfo.copyDiagnostics()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
                Spacer(minLength: 8)
                Button("Close") { close() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            reduceTransparency
                ? theme.color(theme.palette.bg)
                : theme.color(theme.palette.bg).opacity(theme.window.glass ? theme.window.glassOpacity : 1)
        )
        .preferredColorScheme(theme.appearance == "light" ? .light : .dark)
        .tint(theme.color(theme.palette.accent))
        .onExitCommand { close() }
    }

    private func linkButton(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.open(url) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

@MainActor
final class AboutWindowController: NSWindowController {
    init(themeManager: ThemeManager) {
        let theme = themeManager.theme
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Palette"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.appearance = theme.nsAppearance
        window.backgroundColor = theme.nsColor(theme.palette.bg)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        super.init(window: window)
        window.contentView = NSHostingView(rootView: AboutView(
            themeManager: themeManager,
            close: { [weak self] in self?.close() }
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(theme: Theme) {
        window?.appearance = theme.nsAppearance
        window?.backgroundColor = theme.nsColor(theme.palette.bg)
    }

    func show() {
        window?.center()
        guard let window else { return }
        WindowPresentation.present(window)
    }
}
