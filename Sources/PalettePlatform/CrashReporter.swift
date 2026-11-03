import Foundation

nonisolated(unsafe) private var crashLogURL: URL?

/// Minimal crash breadcrumb: uncaught Objective-C exceptions are written next
/// to the app log. Fatal signals are left to macOS's own crash reports.
public enum CrashReporter {
    public static func install(url: URL) {
        crashLogURL = url
        NSSetUncaughtExceptionHandler(paletteUncaughtExceptionHandler)
    }
}

private func paletteUncaughtExceptionHandler(_ exception: NSException) {
    guard let crashLogURL else { return }
    let lines = [
        "Palette crash \(Date())",
        "name: \(exception.name.rawValue)",
        "reason: \(exception.reason ?? "unknown")",
        exception.callStackSymbols.joined(separator: "\n"),
    ]
    try? lines.joined(separator: "\n").write(to: crashLogURL, atomically: true, encoding: .utf8)
}
