import AppKit
import HangarCore

extension Truncation {
    /// How many characters of a *monospaced* font fit in `width` points. Every
    /// advance is identical, so this is exact.
    static func characterBudget(width: CGFloat, font: NSFont) -> Int {
        let advance = font.maximumAdvancement.width
        guard advance > 0 else { return Int(width / 7) }
        return max(1, Int(width / advance))
    }

    /// Middle-truncates `text` to the widest form that still fits `width`.
    ///
    /// Measuring beats estimating for a proportional font: its maximum advance is
    /// far wider than its average glyph, so a character budget derived from it
    /// throws away most of the available space. Only ever called for the handful of
    /// rows on screen, so the measuring loop costs nothing.
    static func fitting(_ text: String, into width: CGFloat, font: NSFont,
                        protecting matched: [Range<String.Index>] = []) -> String {
        guard width > 0 else { return "" }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func measure(_ candidate: String) -> CGFloat {
            (candidate as NSString).size(withAttributes: attributes).width
        }
        if measure(text) <= width { return text }

        // Start from a proportional estimate, then walk down until it fits.
        var limit = max(6, Int(CGFloat(text.count) * width / max(measure(text), 1)))
        var candidate = middle(text, limit: limit, protecting: matched)
        while limit > 6, measure(candidate) > width {
            limit -= 2
            candidate = middle(text, limit: limit, protecting: matched)
        }
        return candidate
    }

    /// Wraps `text` into at most `maxLines` lines that each fit `width`,
    /// measuring rather than counting because a menu font is proportional. If
    /// the text needs more room than that, the last line is middle-truncated
    /// rather than the sentence being cut off at a word.
    static func wrapped(_ text: String, into width: CGFloat, font: NSFont,
                        maxLines: Int) -> [String] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ candidate: String) -> Bool {
            (candidate as NSString).size(withAttributes: attributes).width <= width
        }
        guard !fits(text) else { return [text] }
        var lines = Truncation.wrap(text, maxLines: maxLines, fits: fits)
        if let last = lines.last, !fits(last) {
            lines[lines.count - 1] = fitting(last, into: width, font: font)
        }
        return lines
    }
}
