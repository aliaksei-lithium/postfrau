import Foundation

/// One candidate's match against a query.
public struct FuzzyMatch: Sendable, Hashable {
    /// Higher is better. Only meaningful when comparing matches for the *same* query.
    public var score: Int
    /// Offsets into the candidate's UTF-16 view that the query matched, so the UI can bold them.
    public var matchedOffsets: [Int]

    public init(score: Int, matchedOffsets: [Int]) {
        self.score = score
        self.matchedOffsets = matchedOffsets
    }
}

/// Subsequence matching with scoring, for ⌘K quick open.
///
/// The rules are the ones every fuzzy finder converges on, because they match how people type:
/// characters must appear in order but not adjacently; runs of consecutive matches are worth much
/// more than scattered ones; a match at the start of a word (or after `/`, `-`, `_`) is worth more
/// than one mid-word; and shorter candidates win ties, so `GET /users` beats
/// `GET /users/{id}/permissions` for the query "users".
public enum FuzzyMatcher {
    private static let consecutiveBonus = 15
    private static let wordStartBonus = 10
    private static let firstCharacterBonus = 12
    private static let exactCaseBonus = 2
    private static let leadingGapPenalty = 1
    private static let gapPenalty = 2

    /// Returns nil when the query is not a subsequence of the candidate.
    /// An empty query matches everything with score 0.
    public static func match(query: String, in candidate: String) -> FuzzyMatch? {
        let queryUnits = Array(query.utf16)
        guard !queryUnits.isEmpty else { return FuzzyMatch(score: 0, matchedOffsets: []) }

        let candidateUnits = Array(candidate.utf16)
        guard queryUnits.count <= candidateUnits.count else { return nil }

        var offsets: [Int] = []
        offsets.reserveCapacity(queryUnits.count)
        var score = 0
        var candidateIndex = 0
        var previousMatchIndex = -1

        for queryUnit in queryUnits {
            var found = false
            while candidateIndex < candidateUnits.count {
                let candidateUnit = candidateUnits[candidateIndex]
                if lowercased(candidateUnit) == lowercased(queryUnit) {
                    if candidateIndex == previousMatchIndex + 1, previousMatchIndex >= 0 {
                        score += consecutiveBonus
                    }
                    if candidateIndex == 0 {
                        score += firstCharacterBonus
                    } else if isWordBoundary(candidateUnits[candidateIndex - 1]) {
                        score += wordStartBonus
                    }
                    if candidateUnit == queryUnit { score += exactCaseBonus }

                    if previousMatchIndex >= 0 {
                        score -= (candidateIndex - previousMatchIndex - 1) * gapPenalty
                    } else {
                        score -= candidateIndex * leadingGapPenalty
                    }

                    offsets.append(candidateIndex)
                    previousMatchIndex = candidateIndex
                    candidateIndex += 1
                    found = true
                    break
                }
                candidateIndex += 1
            }
            guard found else { return nil }
        }

        // Prefer the shorter of two otherwise equal candidates.
        score -= candidateUnits.count / 8
        return FuzzyMatch(score: score, matchedOffsets: offsets)
    }

    /// Ranks candidates best-first, dropping non-matches. Ties keep the input order, so an
    /// unchanged query never reshuffles the list.
    public static func rank<Item>(
        _ items: [Item], query: String, key: (Item) -> String
    ) -> [(item: Item, match: FuzzyMatch)] {
        // Written out rather than chained: the compiler cannot type-check the fluent version of
        // this in reasonable time.
        var scored: [(order: Int, item: Item, match: FuzzyMatch)] = []
        scored.reserveCapacity(items.count)
        for (order, item) in items.enumerated() {
            if let match = match(query: query, in: key(item)) {
                scored.append((order, item, match))
            }
        }
        scored.sort { left, right in
            if left.match.score != right.match.score { return left.match.score > right.match.score }
            return left.order < right.order
        }
        return scored.map { (item: $0.item, match: $0.match) }
    }

    private static func lowercased(_ unit: UInt16) -> UInt16 {
        // ASCII fast path; anything else is compared as-is, which is right for the identifiers
        // and URLs this matches against.
        (unit >= 0x41 && unit <= 0x5A) ? unit + 0x20 : unit
    }

    private static func isWordBoundary(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x2F || unit == 0x2D || unit == 0x5F
            || unit == 0x2E || unit == 0x3A || unit == 0x09
    }
}
