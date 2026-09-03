import XCTest
@testable import HangarCore

final class TruncationTests: XCTestCase {

    private let long = "i-0a1b2c3d4e5f60718.xfer.prod.payments.internal.example.com"

    func testShortTextIsUntouched() {
        XCTAssertEqual(Truncation.middle("short", limit: 40), "short")
    }

    func testTruncatesFromTheMiddleKeepingBothEnds() {
        let cut = Truncation.middle(long, limit: 40)
        XCTAssertLessThanOrEqual(cut.count, 40)
        XCTAssertTrue(cut.contains("\u{2026}"))
        XCTAssertTrue(cut.hasPrefix("i-0a1b2c3d4e5f"), cut)
        XCTAssertTrue(cut.hasSuffix("example.com"), cut)
    }

    func testNeverTruncatesThroughTheMatchedSpan() {
        let matches = Fuzzy.ranges(query: "internal", in: long)
        let protected = Truncation.middle(long, limit: 40, protecting: matches)
        XCTAssertTrue(protected.contains("internal"), protected)
        XCTAssertLessThanOrEqual(protected.count, 41, protected)
    }

    func testSpanCalculation() {
        let matches = Fuzzy.ranges(query: "internal", in: long)
        XCTAssertNotNil(Truncation.protectedSpan(in: long, ranges: matches))
        XCTAssertNil(Truncation.protectedSpan(in: long, ranges: []))
    }

    func testDegradesSanelyWhenNarrowerThanBothMinima() {
        let narrow = Truncation.middle(long, limit: 12)
        XCTAssertLessThanOrEqual(narrow.count, 12, narrow)
        XCTAssertTrue(narrow.contains("\u{2026}"), narrow)
    }
}

/// The credential error in the menubar was one long line, so it set the width of
/// the whole menu. These are the cases that decide where the breaks land.
final class WrapTests: XCTestCase {
    /// Stands in for measuring a proportional font.
    private func upTo(_ limit: Int) -> (String) -> Bool {
        { $0.count <= limit }
    }

    func testItBreaksAtAWordBoundary() {
        let lines = Truncation.wrap("the quick brown fox jumps over", maxLines: 2,
                                    fits: upTo(15))
        XCTAssertEqual(lines, ["the quick brown", "fox jumps over"])
    }

    func testItNeverSplitsAWord() {
        for line in Truncation.wrap("alpha bravo charlie delta", maxLines: 3, fits: upTo(11)) {
            for word in line.split(separator: " ") {
                XCTAssertTrue("alpha bravo charlie delta".contains(word))
            }
        }
    }

    func testAWordWiderThanALineKeepsItsOwnLine() {
        let lines = Truncation.wrap("a supercalifragilistic b", maxLines: 3, fits: upTo(6))
        XCTAssertEqual(lines, ["a", "supercalifragilistic", "b"],
                       "a word too wide to fit is still shown, not dropped")
    }

    func testTheLastLineTakesWhateverIsLeft() {
        let lines = Truncation.wrap("one two three four five", maxLines: 2, fits: upTo(7))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(separator: " "), "one two three four five",
                       "the caller truncates one line rather than losing the sentence")
    }

    func testTextThatAlreadyFitsIsLeftAlone() {
        XCTAssertEqual(Truncation.wrap("short enough", maxLines: 2, fits: upTo(40)),
                       ["short enough"])
    }

    func testOneLineOrOneWordIsReturnedWhole() {
        XCTAssertEqual(Truncation.wrap("a b c", maxLines: 1, fits: upTo(1)), ["a b c"])
        XCTAssertEqual(Truncation.wrap("single", maxLines: 3, fits: upTo(1)), ["single"])
    }

    func testTheRealMessageLandsOnTwoLines() {
        let message = "credential_process in profile demo did not return credentials "
            + "AWS accepted. Run it by hand to see what it returns."
        let lines = Truncation.wrap(message, maxLines: 2, fits: upTo(62))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(separator: " "), message)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 66 }, "no line runs away: \(lines)")
    }
}
