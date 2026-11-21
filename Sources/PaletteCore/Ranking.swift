import Foundation

public enum Ranking {
    /// Score bands, best first. Each band reserves 200 points for in-band
    /// bonuses, so a bonus can never lift a match into the band above it.
    private enum Band {
        static let exact = 1000.0
        static let prefix = 800.0
        static let wordStart = 600.0
        static let substring = 400.0
        static let subsequence = 200.0
    }

    public static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scores a single term against a candidate. Returns nil when the term does
    /// not match at all.
    public static func termScore(_ term: String, candidate: String) -> Double? {
        score(normalizedNeedle: normalize(term), haystack: normalize(candidate))
    }

    public static func score(terms: [String], candidate: String) -> Double? {
        guard !terms.isEmpty else { return 0 }
        // Fold each side once: the candidate is shared by every term.
        let haystack = normalize(candidate)
        let needles = terms.map(normalize)
        var total: Double = 0
        for needle in needles {
            guard let value = score(normalizedNeedle: needle, haystack: haystack) else { return nil }
            total += value
        }
        return total / Double(terms.count)
    }

    /// `needle` and `haystack` must already be folded.
    private static func score(normalizedNeedle needle: String, haystack: String) -> Double? {
        guard !needle.isEmpty else { return 0 }
        guard !haystack.isEmpty else { return nil }

        if needle == haystack { return Band.exact }

        let trailing = Double(haystack.count - needle.count)
        // Substring and word-start matches are contiguous runs, so their
        // in-band bonus rewards an early, tight fit; the subsequence tier adds
        // explicit boundary and consecutive-run bonuses below.
        let fitBonus = 199 - min(199, trailing * 4)

        if haystack.hasPrefix(needle) {
            return Band.prefix + max(0, fitBonus)
        }

        if let index = wordBoundaryIndex(of: needle, in: haystack) {
            return Band.wordStart + max(0, fitBonus - Double(index) * 4)
        }

        if let range = haystack.range(of: needle) {
            let index = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return Band.substring + max(0, fitBonus - Double(index) * 4)
        }

        if let score = subsequenceScore(needle, in: haystack) {
            return Band.subsequence + score
        }

        return nil
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
    /// match. Returns 0...199, the in-band bonus of the subsequence tier.
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

            let lengthPenalty = min(60, Double(hayChars.count - needleChars.count) * 2)
            let score = 199
                + Double(min(3, boundaries)) * 20
                + Double(min(60, consecutive * 10))
                - Double(gaps) * 7
                - lengthPenalty
                - Double(min(30, start))
            let clamped = min(199, max(0, score))
            best = max(best ?? clamped, clamped)
        }
        return best
    }
}
