import Foundation

/// Whether a clipboard change should be recorded. Kept free of AppKit so the
/// monitor and the tests share one decision.
public enum ClipboardCapturePolicy {
    /// Pasteboard secrets always win: an app on the ignore list with concealed
    /// content is skipped for both reasons, and a mark on one copy still
    /// protects that copy when the app itself is not ignored.
    public static func shouldCapture(
        frontmostBundleID: String?,
        ignoredApps: Set<String>,
        isMarkedSecret: Bool
    ) -> Bool {
        guard !isMarkedSecret else { return false }
        guard let frontmostBundleID else { return true }
        return !ignoredApps.contains(frontmostBundleID)
    }
}
