import Foundation

/// Subsequence matching over pre-lowercased UTF-8 bytes.
///
/// Scoring runs on every keystroke against the whole fleet, so the hot path
/// allocates nothing and never touches `String`. Candidates are prepared once
/// when the fleet changes; only the query is converted per keystroke.
public enum Fuzzy {
    public typealias Bytes = ContiguousArray<UInt8>

    /// A typed query: whitespace-separated tokens, each matched independently and
    /// in any order. "payments web qa" therefore finds payments-qa-web, which a single
    /// whole-string subsequence never could because it would need a literal space.
    public struct Query: Sendable {
        public let tokens: [Bytes]
        public let terms: [String]

        public init(_ text: String) {
            let pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            self.terms = pieces
            self.tokens = pieces.map(Fuzzy.lowered)
        }

        public var isEmpty: Bool { tokens.isEmpty }
    }

    public static func lowered(_ text: String) -> Bytes {
        var bytes = Bytes()
        bytes.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            bytes.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }
        return bytes
    }

    /// Subsequence score, or nil when the query is not a subsequence at all.
    /// Adjacent hits and hits on a word boundary score higher, which is what
    /// makes acronym-shaped queries such as "ppw" land on payments-prod-web.
    public static func score(_ query: Bytes, in hay: Bytes) -> Int? {
        if query.isEmpty { return 0 }
        if query.count > hay.count { return nil }

        var score = 0
        var hayIndex = 0
        var previousEnd = -1

        for needle in query {
            var found = -1
            var index = hayIndex
            while index < hay.count {
                if hay[index] == needle { found = index; break }
                index += 1
            }
            if found < 0 { return nil }

            if found == previousEnd {
                score += 8
            } else if found == 0 {
                score += 10
            } else {
                let before = hay[found - 1]
                score += (before == 0x2D || before == 0x2E || before == 0x5F || before == 0x20)
                    ? 6 : 1
            }
            previousEnd = found + 1
            hayIndex = found + 1
        }
        // Shorter candidates win ties, so an alias beats a long hostname that
        // happens to contain the same characters.
        return score - hay.count / 8
    }

    /// Ranges for every token, merged. Tokens are order-independent, so each one
    /// searches from the start of the candidate rather than continuing where the
    /// previous token stopped.
    public static func ranges(query: Query, in candidate: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var all: [Range<String.Index>] = []
        for term in query.terms {
            all.append(contentsOf: ranges(query: term, in: candidate))
        }
        guard !all.isEmpty else { return [] }
        all.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [all[0]]
        for range in all.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Character ranges of one term, for highlighting. Only ever called for the
    /// handful of rows actually on screen, so working in `String` is fine here.
    public static func ranges(query: String, in candidate: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var index = candidate.startIndex
        for needle in query.lowercased() {
            guard let found = candidate[index...].firstIndex(where: {
                $0.lowercased() == String(needle)
            }) else { return [] }
            let next = candidate.index(after: found)
            if let last = ranges.last, last.upperBound == found {
                ranges[ranges.count - 1] = last.lowerBound..<next
            } else {
                ranges.append(found..<next)
            }
            index = next
        }
        return ranges
    }
}

/// One fleet member, prepared for search. Built once per refresh rather than per
/// keystroke, which is the whole point.
public struct SearchEntry: Sendable {
    public let instance: Instance
    public let alias: String
    public let hostname: String
    public let metadata: String

    public let aliasBytes: Fuzzy.Bytes
    public let hostnameBytes: Fuzzy.Bytes
    public let metadataBytes: Fuzzy.Bytes

    public init(instance: Instance, alias: String) {
        self.instance = instance
        self.alias = alias
        self.hostname = instance.host ?? instance.privateIP ?? instance.id
        self.metadata = [instance.product, instance.env, instance.envName, instance.role]
            .filter { !$0.isEmpty }.joined(separator: " ")
        self.aliasBytes = Fuzzy.lowered(alias)
        self.hostnameBytes = Fuzzy.lowered(hostname)
        self.metadataBytes = Fuzzy.lowered(metadata)
    }

    /// Best score for one token across the three fields, weighted so an alias hit
    /// outranks a hostname hit, which outranks a tag hit.
    public func score(for token: Fuzzy.Bytes) -> Int? {
        var best: Int?
        if let s = Fuzzy.score(token, in: aliasBytes) { best = s + 24 }
        if let s = Fuzzy.score(token, in: hostnameBytes), s + 8 > (best ?? Int.min) {
            best = s + 8
        }
        if let s = Fuzzy.score(token, in: metadataBytes), s > (best ?? Int.min) {
            best = s
        }
        return best
    }

    /// Every token must match somewhere, in any order. Scores add, so a host that
    /// satisfies each term strongly ranks above one that barely satisfies them.
    public func score(for query: Fuzzy.Query) -> Int? {
        if query.isEmpty { return 0 }
        var total = 0
        for token in query.tokens {
            guard let best = score(for: token) else { return nil }
            total += best
        }
        return total
    }
}

