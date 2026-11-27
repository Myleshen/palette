import Foundation

/// The wallpaper-follow timer's signature bookkeeping. The signature records a
/// palette that was actually written: a failed read must be retried, and a
/// reseed from a config reload must not swallow an in-flight change.
struct WallpaperFollowState {
    private(set) var lastSignature = ""
    private(set) var inFlight = false

    /// Called when polling starts. An in-flight apply keeps ownership of the
    /// signature, so the next tick does not think the change was handled.
    mutating func reseed(_ signature: String) {
        guard !inFlight else { return }
        lastSignature = signature
    }

    /// Starts one apply when the desktop picture changed; false means skip.
    mutating func begin(_ signature: String) -> Bool {
        guard !inFlight, signature != lastSignature else { return false }
        inFlight = true
        return true
    }

    mutating func finish(signature: String, succeeded: Bool) {
        inFlight = false
        if succeeded {
            lastSignature = signature
        }
    }
}
