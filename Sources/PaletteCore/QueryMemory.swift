import CryptoKit
import Foundation

/// Remembers which row was picked after a short plain query, so the same
/// prefix can rank that row first next time. Only a digest of the prefix is
/// stored, never the text that was typed.
public enum QueryMemory {
    /// Queries outside this length are too vague or too specific to learn from.
    public static let minLength = 2
    public static let maxLength = 12

    /// The normalised text a query is learned under, or nil when the query is
    /// outside the learning range.
    public static func learnablePrefix(_ query: String) -> String? {
        let normalised = Ranking.normalize(query).lowercased()
        guard normalised.count >= minLength, normalised.count <= maxLength else { return nil }
        return normalised
    }

    /// SHA-256 hex of the first 12 characters.
    public static func digest(_ prefix: String) -> String {
        let head = String(prefix.prefix(maxLength))
        return SHA256.hash(data: Data(head.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
