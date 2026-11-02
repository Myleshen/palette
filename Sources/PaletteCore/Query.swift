import Foundation

public struct TriggerEntry: Equatable, Sendable {
    public var trigger: String
    public var providerID: String
    public var priority: Int

    public init(trigger: String, providerID: String, priority: Int = 0) {
        self.trigger = trigger
        self.providerID = providerID
        self.priority = priority
    }
}

public struct ParsedQuery: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case global
        case provider(String)
    }

    public var raw: String
    public var scope: Scope
    public var text: String
    public var trigger: String?

    public init(raw: String, scope: Scope, text: String, trigger: String? = nil) {
        self.raw = raw
        self.scope = scope
        self.text = text
        self.trigger = trigger
    }

    public var providerID: String? {
        if case .provider(let id) = scope { return id }
        return nil
    }

    public var isBound: Bool { providerID != nil }
}

/// Resolves Noctalia-style prefixes: a shared prefix character plus a bare
/// trigger declared by each provider. Absolute paths such as `/Users/me` do not
/// collide because triggers are words, not paths.
public struct QueryParser: Sendable {
    public var prefix: String
    public var triggers: [TriggerEntry]

    public init(prefix: String = "/", triggers: [TriggerEntry]) {
        self.prefix = prefix.isEmpty ? "/" : prefix
        self.triggers = triggers.sorted {
            if $0.trigger.count != $1.trigger.count { return $0.trigger.count > $1.trigger.count }
            return $0.providerID < $1.providerID
        }
    }

    public func parse(_ input: String) -> ParsedQuery {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ParsedQuery(raw: raw, scope: .global, text: "")
        }

        guard raw.hasPrefix(prefix) else {
            return ParsedQuery(raw: raw, scope: .global, text: raw)
        }

        let afterPrefix = raw.dropFirst(prefix.count)
        let token = afterPrefix.prefix { !$0.isWhitespace }
        guard !token.isEmpty else {
            return ParsedQuery(raw: raw, scope: .global, text: "")
        }

        let remainderStart = afterPrefix.index(afterPrefix.startIndex, offsetBy: token.count)
        let remainder = String(afterPrefix[remainderStart...])

        // The trigger must be followed by whitespace or the end of input.
        if !remainder.isEmpty, !remainder.first!.isWhitespace {
            return ParsedQuery(raw: raw, scope: .global, text: raw)
        }

        let lowered = token.lowercased()
        for entry in triggers where entry.trigger.lowercased() == lowered {
            return ParsedQuery(
                raw: raw,
                scope: .provider(entry.providerID),
                text: remainder.trimmingCharacters(in: .whitespacesAndNewlines),
                trigger: entry.trigger
            )
        }

        return ParsedQuery(raw: raw, scope: .global, text: raw)
    }

    /// Completes the typed token to a provider prefix, used by Tab.
    public func completion(for input: String) -> String? {
        let trimmed = input
        guard trimmed.hasPrefix(prefix) else { return nil }
        let token = trimmed.dropFirst(prefix.count).prefix { !$0.isWhitespace }
        guard !token.isEmpty else { return nil }
        let lowered = token.lowercased()
        if let exact = triggers.first(where: { $0.trigger.lowercased() == lowered }) {
            return prefix + exact.trigger + " "
        }
        let matches = triggers
            .filter { $0.trigger.lowercased().hasPrefix(lowered) }
            .sorted {
                if $0.trigger.count != $1.trigger.count { return $0.trigger.count < $1.trigger.count }
                return $0.trigger < $1.trigger
            }
        guard let match = matches.first else { return nil }
        return prefix + match.trigger + " "
    }
}
