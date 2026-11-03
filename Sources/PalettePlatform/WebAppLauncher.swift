import AppKit
import Foundation

/// Launches a configured web app as a Chromium app window (`--app=…`), using a
/// dedicated Palette profile. That keeps web apps out of normal browser tabs and
/// gives them their own window without sharing the everyday browser session.
public struct WebAppLaunchSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum WebAppLauncher {
    public static var profileRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Palette/WebApps", isDirectory: true)
    }

    public static func launchSpec(urlString: String, browser: String) -> WebAppLaunchSpec? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let appPath = ToolLocator.shared.appPath(named: browser),
              let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
              let executable = bundle.executableURL?.path else { return nil }

        let slug = browser.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let profile = profileRoot.appendingPathComponent(String(slug), isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        return WebAppLaunchSpec(
            executable: executable,
            arguments: [
                "--app=\(url.absoluteString)",
                "--user-data-dir=\(profile.path)",
                "--no-first-run",
                "--no-default-browser-check",
                "--window-size=1280,900",
            ]
        )
    }
}
