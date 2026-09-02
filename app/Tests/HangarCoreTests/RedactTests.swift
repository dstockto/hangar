import XCTest
@testable import HangarCore

/// A log nobody dares attach is a log that does not exist, so anything naming
/// someone's infrastructure is a digest before it reaches either sink.
final class RedactTests: XCTestCase {

    func testTheOriginalNeverSurvives() {
        let host = "web-1.prod.payments.example.com"
        let redacted = Redact.host(host)
        XCTAssertFalse(redacted.contains("payments"))
        XCTAssertFalse(redacted.contains("example.com"))
        XCTAssertFalse(redacted.contains("web-1"))
    }

    func testTheSameHostReadsTheSameEveryTime() {
        XCTAssertEqual(Redact.host("db.prod.example.com"),
                       Redact.host("db.prod.example.com"))
        XCTAssertEqual(Redact.instance("i-0a1b2c3d"), Redact.instance("i-0a1b2c3d"))
    }

    func testDifferentHostsReadDifferently() {
        XCTAssertNotEqual(Redact.host("a.example.com"), Redact.host("b.example.com"))
        XCTAssertNotEqual(Redact.instance("i-0a1b2c3d"), Redact.instance("i-0a1b2c3e"))
    }

    func testHostsAndInstancesArePrefixedSoALineReads() {
        XCTAssertTrue(Redact.host("a.example.com").hasPrefix("host#"))
        XCTAssertTrue(Redact.instance("i-0a1b2c3d").hasPrefix("i#"))
        XCTAssertEqual(Redact.host("").suffix(4), "none")
    }
}
