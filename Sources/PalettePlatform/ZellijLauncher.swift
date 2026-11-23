import Foundation
import PaletteCore

/// One place that both terminal paths use to reach a zellij session: read the
/// live session list, clear a dead session of the same name, then attach.
public enum ZellijLauncher {
    public struct Preparation: Sendable, Equatable {
        /// Sanitized name the attach must use.
        public var name: String
        /// Set when dropping a stale session failed; attaching may still work.
        public var warning: String?
    }

    /// Reads `zellij list-sessions` and drops a dead session of the same name
    /// so attach creates a fresh one instead of resurrecting or failing.
    public static func prepare(name rawName: String) async -> Preparation {
        let zellij = ToolLocator.shared.path(for: "zellij") ?? "zellij"
        let listing = (try? await ProcessRunner.run([zellij, "list-sessions", "--no-formatting"], timeout: 2.5))?
            .stdoutString ?? ""
        let plan = ZellijAttach.plan(name: rawName, listing: listing)
        guard case .reset(let name) = plan else { return Preparation(name: plan.name) }

        let delete = try? await ProcessRunner.run([zellij, "delete-session", "--force", name], timeout: 2.5)
        var warning: String?
        if let delete, delete.status != 0 {
            let text = delete.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            warning = "could not drop the old session \"\(name)\""
            if !text.isEmpty { warning? += ": " + text }
        }
        return Preparation(name: name, warning: warning)
    }

    /// Shell line for an external terminal. Attach is retried once because the
    /// session can die between the session list and the attach.
    public static func attachScript(zellij: String, name: String, create: Bool) -> String {
        let tool = shellQuote(zellij)
        let session = shellQuote(name)
        let attach = "\(tool) attach " + (create ? "--create " : "") + session
        return "\(attach) || { \(tool) delete-session --force \(session); exec \(tool) attach --create \(session); }"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
