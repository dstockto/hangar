import Foundation

/// Middle truncation for host text, per the brand kit: keep the beginning of the
/// alias and the final unique suffix, and never cut through the matched span.
public enum Truncation {
    public static let ellipsis = "\u{2026}"

    /// Truncates `text` to `limit` characters, removing from the middle and
    /// shifting the removal window so the whole match plus four characters of
    /// context on each side survives.
    public static func middle(_ text: String, limit: Int,
                       protecting matched: [Range<String.Index>] = [],
                       leadMinimum: Int = 18, tailMinimum: Int = 12) -> String {
        let characters = Array(text)
        guard limit > 0, characters.count > limit else { return text }
        guard limit > leadMinimum + tailMinimum else {
            // Too narrow to honour both minima; keep the head and the tail we can.
            let tail = max(1, limit / 3)
            let lead = max(1, limit - tail - 1)
            return String(characters.prefix(lead)) + ellipsis + String(characters.suffix(tail))
        }

        var lead = leadMinimum
        var tail = limit - leadMinimum - 1
        if tail < tailMinimum {
            tail = tailMinimum
            lead = limit - tailMinimum - 1
        }

        // Widen the kept head so the protected span stays visible when it sits
        // inside the region that would otherwise be removed.
        if let span = protectedSpan(in: text, ranges: matched) {
            let contextStart = max(0, span.lowerBound - 4)
            let contextEnd = min(characters.count, span.upperBound + 4)
            if contextEnd > characters.count - tail && contextStart >= lead {
                // The match lives in the tail region: grow the tail instead.
                let neededTail = characters.count - contextStart
                if neededTail + 1 < limit {
                    tail = neededTail
                    lead = limit - tail - 1
                }
            } else if contextEnd > lead {
                let neededLead = contextEnd
                if neededLead + tailMinimum + 1 <= limit {
                    lead = neededLead
                    tail = limit - lead - 1
                }
            }
        }

        lead = max(1, min(lead, characters.count - 1))
        tail = max(1, min(tail, characters.count - lead - 1))
        return String(characters.prefix(lead)) + ellipsis + String(characters.suffix(tail))
    }

    /// Character offsets spanning all matched ranges.
    public static func protectedSpan(in text: String,
                              ranges: [Range<String.Index>]) -> Range<Int>? {
        guard !ranges.isEmpty else { return nil }
        var lowest = Int.max
        var highest = 0
        for range in ranges {
            lowest = min(lowest, text.distance(from: text.startIndex, to: range.lowerBound))
            highest = max(highest, text.distance(from: text.startIndex, to: range.upperBound))
        }
        return lowest..<highest
    }

}
