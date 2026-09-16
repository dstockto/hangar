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
        /// The tokens with their punctuation folded out, for `admits`. Done once
        /// here rather than per field per host, which is three times a fleet.
        public let words: [Bytes]
        public let terms: [String]

        public init(_ text: String) {
            let pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            self.terms = pieces
            let tokens = pieces.map(Fuzzy.lowered)
            self.tokens = tokens
            self.words = tokens.map(Fuzzy.withoutSeparators)
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

    /// The punctuation a host name is written with: `-`, `.`, `_` and space.
    static func isSeparator(_ byte: UInt8) -> Bool {
        byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x20
    }

    /// The same question asked of a character, for the highlight path, which
    /// works in `String`. One list, so the two cannot drift apart.
    static func isSeparator(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return isSeparator(ascii)
    }

    /// Whether a token is anchored to how the name is written, rather than taking
    /// one letter here and another three labels away.
    ///
    /// Subsequence alone is too generous on a name with six labels in it: `qa`
    /// took its `q` from a role and its `a` from the region, so every host in the
    /// product matched and typing more never narrowed. A token has to be one of
    /// three things instead, each of which a person can point at on screen.
    ///
    /// The labels are found by scanning rather than precomputed. Precomputing
    /// them cost a split of all three fields of every host at index time, which
    /// is work done for hosts no one goes on to search for; this is work done
    /// only for a field a score already matched.
    public static func admits(_ token: Bytes, in hay: Bytes) -> Bool {
        if token.isEmpty { return true }
        // A name is split on its separators, so none of the three routes can hold
        // one: a typed separator is punctuation rather than a letter to find, and
        // without this every alias the menu displays stopped matching when it was
        // typed back. Already folded when it arrives from a Query, so this scans.
        let word = withoutSeparators(token)
        if word.isEmpty { return true }
        // Typed straight through the separators: `paymentsprod` for `payments prod`,
        // and `payments-prod` now that it folds to the same word. First because a
        // prefix of a label lands here in one pass, and a prefix is what a person
        // has typed for most of the keystrokes on the way to a whole word.
        if containsSkippingSeparators(hay, word) { return true }
        // Inside one label: `wstore` in `webstore`, `torq` in `torque`.
        var start = 0
        while start < hay.count {
            if isSeparator(hay[start]) { start += 1; continue }
            var end = start
            while end < hay.count, !isSeparator(hay[end]) { end += 1 }
            if isSubsequence(word, of: hay, in: start..<end) { return true }
            start = end
        }
        // Label initials, which is what makes `ppw` find `payments-prod-web`.
        return matchesInitials(word, hay)
    }

    /// The typed token with its punctuation dropped. Returns the token untouched
    /// when it holds none, which is almost every keystroke.
    static func withoutSeparators(_ token: Bytes) -> Bytes {
        guard token.contains(where: isSeparator) else { return token }
        var word = Bytes()
        word.reserveCapacity(token.count)
        for byte in token where !isSeparator(byte) { word.append(byte) }
        return word
    }

    static func isSubsequence(_ token: Bytes, of hay: Bytes,
                              in range: Range<Int>) -> Bool {
        if token.count > range.count { return false }
        var index = range.lowerBound
        for needle in token {
            while index < range.upperBound, hay[index] != needle { index += 1 }
            if index == range.upperBound { return false }
            index += 1
        }
        return true
    }

    /// Whether the token reads contiguously through the name once its separators
    /// are passed over, which is what `payments-prod` and `paymentsprod` both are.
    static func containsSkippingSeparators(_ hay: Bytes, _ token: Bytes) -> Bool {
        if token.isEmpty { return true }
        var start = 0
        while start < hay.count {
            if hay[start] == token[0] {
                var index = start
                var offset = 0
                while index < hay.count, offset < token.count {
                    if isSeparator(hay[index]) { index += 1; continue }
                    if hay[index] != token[offset] { break }
                    index += 1
                    offset += 1
                }
                if offset == token.count { return true }
            }
            start += 1
        }
        return false
    }

    /// Whether the token reads off the first byte of each label, in order, which
    /// is what makes an acronym an acronym.
    static func matchesInitials(_ token: Bytes, _ hay: Bytes) -> Bool {
        var offset = 0
        var index = 0
        while index < hay.count, offset < token.count {
            if isSeparator(hay[index]) { index += 1; continue }
            if hay[index] == token[offset] { offset += 1 }
            while index < hay.count, !isSeparator(hay[index]) { index += 1 }
        }
        return offset == token.count
    }

    /// Ranges for every token, merged. Tokens are order-independent, so each one
    /// searches from the start of the candidate rather than continuing where the
    /// previous token stopped.
    ///
    /// Held to the same `admits` rule the score is, because a highlight is the
    /// only account of itself the search gives. When it was not, a term could
    /// qualify a host and paint nothing a reader could see: both its characters
    /// landed inside ranges another term had already painted, so a term that
    /// matched nothing and a term that matched invisibly looked identical.
    public static func ranges(query: Query, in candidate: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var all: [Range<String.Index>] = []
        for term in query.terms {
            all.append(contentsOf: ranges(term: term, in: candidate))
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
        ranges(term: query, in: candidate)
    }

    /// One term, confined to the label it actually matched when it matched one.
    ///
    /// Confining matters as much as admitting: a term that fits inside `torque`
    /// should underline `torque`, not scatter itself from there to the end of the
    /// domain. Only a query spelled straight through the separators, or read off
    /// the label initials, is painted across the whole name, because that is what
    /// those two genuinely match.
    static func ranges(term: String, in candidate: String) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        let token = Fuzzy.lowered(term)
        guard admits(token, in: Fuzzy.lowered(candidate)) else { return [] }
        var best: (score: Int, range: Range<String.Index>)?
        for label in labelRanges(of: candidate) {
            let bytes = Fuzzy.lowered(String(candidate[label]))
            guard isSubsequence(token, of: bytes, in: 0..<bytes.count),
                  let s = score(token, in: bytes) else { continue }
            if s > (best?.score ?? Int.min) { best = (s, label) }
        }
        let window = best?.range ?? candidate.startIndex..<candidate.endIndex
        return ranges(term: term, in: candidate, within: window)
    }

    /// The parts of a name between its separators, as ranges into the name.
    static func labelRanges(of candidate: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = candidate.startIndex
        while index < candidate.endIndex {
            if isSeparator(candidate[index]) {
                if let from = start { ranges.append(from..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = candidate.index(after: index)
        }
        if let from = start { ranges.append(from..<candidate.endIndex) }
        return ranges
    }

    private static func ranges(term: String, in candidate: String,
                               within window: Range<String.Index>) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = window.lowerBound
        for needle in term.lowercased() {
            guard let found = candidate[index..<window.upperBound].firstIndex(where: {
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
        // A repeated value would let one token take characters from two copies,
        // matching what no single field holds, so typing more stopped narrowing.
        // Deduplicated on the lowered bytes search actually compares, so this is
        // never wider than the haystack: folding more would hide a findable name.
        var seen: [Fuzzy.Bytes] = []
        var fields: [String] = []
        for field in [instance.product, instance.env, instance.envName, instance.role]
        where !field.isEmpty {
            let lowered = Fuzzy.lowered(field)
            if !seen.contains(lowered) {
                seen.append(lowered)
                fields.append(field)
            }
        }
        self.metadata = fields.joined(separator: " ")
        self.aliasBytes = Fuzzy.lowered(alias)
        self.hostnameBytes = Fuzzy.lowered(hostname)
        self.metadataBytes = Fuzzy.lowered(metadata)
    }

    /// Best score for one token across the three fields, weighted so an alias hit
    /// outranks a hostname hit, which outranks a tag hit.
    ///
    /// A field only offers a score for a token it `admits`. The weights are the
    /// ones that were already tuned: anchoring decides whether a field answers at
    /// all, and nothing about how loudly it answers, so ranking is unchanged among
    /// the hosts that still match.
    public func score(for token: Fuzzy.Bytes) -> Int? {
        score(for: token, word: Fuzzy.withoutSeparators(token))
    }

    /// `word` is `token` with its punctuation already folded out, which the query
    /// does once for the whole fleet.
    func score(for token: Fuzzy.Bytes, word: Fuzzy.Bytes) -> Int? {
        // Both have to hold, and the score is the cheaper rejection: it walks the
        // field once and stops dead on a byte the field does not contain, which is
        // most hosts on most keystrokes. Anchoring is only asked about a match.
        var best: Int?
        if let s = Fuzzy.score(token, in: aliasBytes),
           Fuzzy.admits(word, in: aliasBytes) { best = s + 24 }
        if let s = Fuzzy.score(token, in: hostnameBytes), s + 8 > (best ?? Int.min),
           Fuzzy.admits(word, in: hostnameBytes) {
            best = s + 8
        }
        if let s = Fuzzy.score(token, in: metadataBytes), s > (best ?? Int.min),
           Fuzzy.admits(word, in: metadataBytes) {
            best = s
        }
        return best
    }

    /// Every token must match somewhere, in any order. Scores add, so a host that
    /// satisfies each term strongly ranks above one that barely satisfies them.
    public func score(for query: Fuzzy.Query) -> Int? {
        if query.isEmpty { return 0 }
        var total = 0
        for index in query.tokens.indices {
            guard let best = score(for: query.tokens[index],
                                   word: query.words[index]) else { return nil }
            total += best
        }
        return total
    }
}

