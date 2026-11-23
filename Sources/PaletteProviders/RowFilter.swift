import Foundation
import PaletteCore
import PalettePlatform

/// Row filtering for providers that hold a whole list in memory (`/atlas`,
/// `/proj`). Big lists go through fzf, the same engine `/neof` uses; small ones
/// and machines without fzf fall back to `Ranking`.
///
/// This only decides *which* rows match. Each provider keeps its own ordering
/// (inbox first, score, newest), so fzf never reshuffles a section.
public enum RowFilter {
    /// Below this a process round trip costs more than the match itself.
    public static let fzfThreshold = 500

    /// Indices into `candidates` that match, in no particular order.
    public static func matchingIndices(
        query: String,
        candidates: [String],
        ranker: any FuzzyPathRanking = FzfRanker()
    ) async -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(candidates.indices) }
        guard candidates.count >= fzfThreshold else {
            return rankingIndices(query: trimmed, candidates: candidates)
        }
        var indexByCandidate: [String: Int] = [:]
        indexByCandidate.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() where indexByCandidate[candidate] == nil {
            indexByCandidate[candidate] = index
        }
        // A missing or failing fzf must never empty the list.
        guard let ranked = try? await ranker.rank(
            paths: candidates,
            query: trimmed,
            limit: candidates.count
        ) else {
            return rankingIndices(query: trimmed, candidates: candidates)
        }
        return ranked.compactMap { indexByCandidate[$0] }
    }

    /// The in-process fallback, also used by the tests.
    public static func rankingIndices(query: String, candidates: [String]) -> [Int] {
        candidates.indices.filter {
            Ranking.score(query: query, candidate: candidates[$0]) != nil
        }
    }
}

public enum ProviderToolRequirements {
    /// Tools a provider cannot run without. Paths providers are matched by
    /// engine, because a user provider picks its own id.
    public static func requirements(for provider: any PaletteProvider) -> [ProviderRequirement] {
        if provider is PathsProvider { return ProviderRequirements.pathTools }
        return ProviderRequirements.requirements(forProviderID: provider.descriptor.id)
    }
}
