import Foundation

public enum Ranking {
    public static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scores a single term against a candidate. Returns nil when the term does
    /// not match at all.
    public static func termScore(_ term: String, candidate: String) -> Double? {
        let needle = normalize(term)
        let haystack = normalize(candidate)
        guard !needle.isEmpty else { return 0 }
        guard !haystack.isEmpty else { return nil }

        if needle == haystack { return 1000 }

        if haystack.hasPrefix(needle) {
            return 900 - min(80, Double(haystack.count - needle.count) * 2)
        }

        if let index = wordBoundaryIndex(of: needle, in: haystack) {
            return 780 - min(120, Double(index) * 3)
        }

        if let range = haystack.range(of: needle) {
            let index = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let lengthPenalty = Double(haystack.count - needle.count)
            return 650 - min(150, Double(index) * 4) - min(50, lengthPenalty)
        }

        if let gaps = subsequenceGaps(needle, in: haystack) {
            return max(80, 400 - Double(gaps) * 4 - Double(haystack.count - needle.count))
        }

        return nil
    }

    public static func score(terms: [String], candidate: String) -> Double? {
        guard !terms.isEmpty else { return 0 }
        var total: Double = 0
        for term in terms {
            guard let value = termScore(term, candidate: candidate) else { return nil }
            total += value
        }
        return total / Double(terms.count)
    }

    public static func score(query: String, candidate: String) -> Double? {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return score(terms: terms, candidate: candidate)
    }

    /// A gentle boost, deliberately small enough to only break ties among
    /// similarly good matches. 30-day half-life.
    public static func frecencyBoost(uses: Int, lastUsed: Date?, now: Date = Date()) -> Double {
        guard uses > 0 else { return 0 }
        let age = lastUsed.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let halfLifeDays = 30.0
        let decay = pow(0.5, age / (halfLifeDays * 86_400))
        return 0.30 * log1p(Double(uses)) * decay
    }

    public static func merge(_ items: [PaletteItem], boosts: [String: Double] = [:]) -> [PaletteItem] {
        var best: [String: PaletteItem] = [:]
        for item in items {
            var candidate = item
            candidate.score += boosts[item.stableID] ?? 0
            if let existing = best[candidate.stableID] {
                if candidate.score > existing.score {
                    best[candidate.stableID] = candidate
                }
            } else {
                best[candidate.stableID] = candidate
            }
        }
        return best.values.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.stableID < rhs.stableID
        }
    }

    private static func wordBoundaryIndex(of needle: String, in haystack: String) -> Int? {
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if range.lowerBound == haystack.startIndex {
                return 0
            }
            let previous = haystack[haystack.index(before: range.lowerBound)]
            if previous.isWhitespace || "/.-_:".contains(previous) {
                return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return nil
    }

    private static func subsequenceGaps(_ needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        var gaps = 0
        var lastMatch: String.Index?
        var haystackIndex = haystack.startIndex

        for character in needle {
            var found = false
            while haystackIndex < haystack.endIndex {
                if haystack[haystackIndex] == character {
                    if let last = lastMatch {
                        gaps += haystack.distance(from: last, to: haystackIndex) - 1
                    }
                    lastMatch = haystackIndex
                    haystackIndex = haystack.index(after: haystackIndex)
                    found = true
                    break
                }
                haystackIndex = haystack.index(after: haystackIndex)
            }
            if !found { return nil }
        }
        return gaps
    }
}
