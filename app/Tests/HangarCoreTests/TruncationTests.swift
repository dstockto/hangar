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
