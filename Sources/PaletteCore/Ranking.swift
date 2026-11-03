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

        if let score = subsequenceScore(needle, in: haystack) {
            return score
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

    /// fzf-style subsequence scoring: every character must appear in order, but
    /// matching at a word boundary and keeping runs together beats a scattered
    /// match. The ceiling stays below the substring tier so exact and substring
    /// matches always rank higher.
    private static func subsequenceScore(_ needle: String, in haystack: String) -> Double? {
        guard !needle.isEmpty else { return 0 }
        let needleChars = Array(needle)
        let hayChars = Array(haystack)
        guard needleChars.count <= hayChars.count else { return nil }

        var best: Double?
        for start in hayChars.indices where hayChars[start] == needleChars[0] {
            var positions: [Int] = [start]
            var cursor = start + 1
            var matched = true

            for character in needleChars.dropFirst() {
                while cursor < hayChars.count, hayChars[cursor] != character {
                    cursor += 1
                }
                guard cursor < hayChars.count else {
                    matched = false
                    break
                }
                positions.append(cursor)
                cursor += 1
            }
            guard matched else { continue }

            var gaps = 0
            var consecutive = 0
            var boundaries = 0
            for (offset, position) in positions.enumerated() {
                if offset > 0 {
                    let gap = position - positions[offset - 1] - 1
                    gaps += gap
                    if gap == 0 { consecutive += 1 }
                }
                if position == 0 {
                    boundaries += 1
                } else {
                    let previous = hayChars[position - 1]
                    if previous.isWhitespace || "/.-_:".contains(previous) {
                        boundaries += 1
                    }
                }
            }

            let lengthPenalty = min(80, Double(hayChars.count - needleChars.count) * 2)
            let score = 250
                + Double(boundaries) * 45
                + Double(min(40, consecutive * 10))
                - Double(gaps) * 7
                - lengthPenalty
                - Double(min(30, start))
            let clamped = min(430, max(80, score))
            best = max(best ?? clamped, clamped)
        }
        return best
    }
}
