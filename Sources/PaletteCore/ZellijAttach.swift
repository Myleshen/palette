import Foundation

/// What has to happen before zellij can attach to a session name.
public enum ZellijAttachPlan: Equatable, Sendable {
    /// The name is free or live: attach and create when missing.
    case attach(name: String)
    /// A dead session still owns the name, which makes attach resurrect it or
    /// fail: drop it first, then attach.
    case reset(name: String)

    public var name: String {
        switch self {
        case .attach(let name), .reset(let name): return name
        }
    }
}

public enum ZellijAttach {
    /// zellij rejects everything outside this set in a session name.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Sanitizes a name for zellij and keeps it usable. A name with no safe
    /// characters left becomes `palette-<hash>`, so two unusable names never
    /// collapse onto the same session.
    public static func sessionName(_ raw: String) -> String {
        let cleaned = raw.map { allowed.contains($0) ? $0 : "-" }
        let trimmed = String(String(cleaned).prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if !trimmed.isEmpty { return trimmed }
        // FNV-1a: short, stable, and no Foundation hashing salt.
        let digest = raw.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return "palette-" + String(digest, radix: 36)
    }

    /// `listing` is the output of `zellij list-sessions --no-formatting`.
    /// An exited session of the same name would make attach resurrect stale
    /// pane state or fail, so it is dropped before attaching.
    public static func plan(name rawName: String, listing: String) -> ZellijAttachPlan {
        let name = sessionName(rawName)
        let stale = listing.split(separator: "\n").contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.split(separator: " ", maxSplits: 1).first.map(String.init) == name else {
                return false
            }
            let lower = text.lowercased()
            return lower.contains("exited") || lower.contains("resurrect")
        }
        return stale ? .reset(name: name) : .attach(name: name)
    }

    /// The failure text zellij prints when the session a command named is gone
    /// or still holding a dead pane. All of them clear with one forced delete.
    public static func isStaleSessionFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        let markers = [
            "session name already in use",
            "there is no active session",
            "no active sessions",
            "attach to resurrect",
            "resurrect",
            "session does not exist",
            "failed to find session",
        ]
        return markers.contains { text.contains($0) }
    }
}
