import XCTest
@testable import HangarCore

final class FuzzyTests: XCTestCase {

    private func score(_ query: String, _ candidate: String) -> Int? {
        Fuzzy.score(Fuzzy.lowered(query), in: Fuzzy.lowered(candidate))
    }

    func testSubsequenceMatching() {
        XCTAssertNotNil(score("ppw", "payments-prod-web-1"))
        XCTAssertNil(score("zzz", "payments-prod-web-1"))
        XCTAssertEqual(score("", "anything"), 0)
        XCTAssertNil(score("payments-prod-web-1-and-more", "web"),
                     "a query longer than the candidate cannot match")
        XCTAssertNotNil(score("PPW", "payments-prod-web"))
    }

    func testWordBoundaryHitsOutrankScatteredHits() {
        let boundary = score("ppw", "payments-prod-web")!
        let scattered = score("ppw", "xpxpxwx")!
        XCTAssertGreaterThan(boundary, scattered)
    }

    func testShorterCandidatesWinTies() {
        XCTAssertGreaterThan(score("web", "web")!,
                             score("web", "a-very-long-name-with-web-inside")!)
    }

    func testHighlightRanges() {
        XCTAssertEqual(Fuzzy.ranges(query: "ppw", in: "payments-prod-web").count, 3)
        XCTAssertEqual(Fuzzy.ranges(query: "web", in: "payments-prod-web").count, 1,
                       "adjacent ranges coalesce")
    }
}

final class MultiTokenSearchTests: XCTestCase {

    private let qaWeb = SearchEntry(instance: Fixture.instance([
        "product": "payments", "env": "qa", "Name": "web",
        "hostname": "web.qa.payments.internal.example.com"]), alias: "payments-qa-web")
    private let prodWeb = SearchEntry(instance: Fixture.instance([
        "product": "payments", "env": "prod", "Name": "web",
        "hostname": "web.prod.payments.internal.example.com"]), alias: "payments-prod-web-1")
    private let mediaQaDb = SearchEntry(instance: Fixture.instance([
        "product": "media", "env": "qa", "Name": "db",
        "hostname": "db.qa.media.internal.example.com"]), alias: "media-qa-db")

    func testTermsMatchInAnyOrder() {
        XCTAssertNotNil(qaWeb.score(for: Fuzzy.Query("payments web qa")))
        XCTAssertNotNil(qaWeb.score(for: Fuzzy.Query("qa web payments")))
        XCTAssertNotNil(qaWeb.score(for: Fuzzy.Query("paymentsqaweb")))
    }

    func testEveryTermIsRequired() {
        XCTAssertNil(qaWeb.score(for: Fuzzy.Query("payments web zzzz")))
        XCTAssertNil(mediaQaDb.score(for: Fuzzy.Query("payments qa")),
                     "a term matching another host must not leak")
        XCTAssertNil(prodWeb.score(for: Fuzzy.Query("payments web qa")),
                     "terms narrow across environments")
        XCTAssertNotNil(prodWeb.score(for: Fuzzy.Query("payments web prod")))
    }

    func testWhitespaceIsTolerated() {
        XCTAssertNotNil(qaWeb.score(for: Fuzzy.Query("  payments   web  ")))
        XCTAssertNotNil(qaWeb.score(for: Fuzzy.Query("payments web ")))
        XCTAssertEqual(qaWeb.score(for: Fuzzy.Query("   ")), 0)
    }

    func testTermsMayMatchDifferentFields() {
        XCTAssertNotNil(qaWeb.score(for: Fuzzy.Query("internal payments")))
    }

    func testHighlightingCoversEveryTerm() {
        let ranges = Fuzzy.ranges(query: Fuzzy.Query("payments qa"), in: "payments-qa-web")
        XCTAssertGreaterThanOrEqual(ranges.count, 2)
    }

    func testMoreSpecificQueriesScoreHigher() {
        XCTAssertGreaterThan(qaWeb.score(for: Fuzzy.Query("payments qa web"))!,
                             qaWeb.score(for: Fuzzy.Query("payments"))!)
    }
}

/// The shape of the real problem: 249 hosts and a query typed one character at a
/// time. This is the path that used to rebuild and sort the whole alias table
/// once per instance per keystroke.
final class SearchPerformanceTests: XCTestCase {

    private static let fleet: [SearchEntry] = {
        let products = ["payments", "search", "media", "identity", "billing", "infra"]
        let envs = ["prod", "qa", "uat", "sb", "dev"]
        let roles = ["web", "db", "etl", "xfer", "worker", "scheduler", "reports",
                     "ci", "grafana"]
        return (0..<249).map { i in
            let role = roles[i % roles.count]
            let env = envs[i % envs.count]
            let product = products[i % products.count]
            let id = "i-0\(String(format: "%015x", i))"
            let instance = Fixture.instance(
                ["product": product, "env": env, "Name": role,
                 "hostname": "\(id).\(role).\(env).\(product).example.com"], id: id)
            return SearchEntry(instance: instance, alias: instance.aliasStem + "-\(i)")
        }
    }()

    private func timeTyping(_ text: String, incremental: Bool) -> (ms: Double, count: Int) {
        let fleet = SearchPerformanceTests.fleet
        var results = fleet
        var last = ""
        var final = 0
        let start = Date()
        for end in 1...text.count {
            let query = String(text.prefix(end))
            let needle = Fuzzy.Query(query)
            let source = (incremental && query.hasPrefix(last) && !last.isEmpty)
                ? results : fleet
            var scored: [(SearchEntry, Int)] = []
            scored.reserveCapacity(source.count)
            for entry in source {
                if let score = entry.score(for: needle) { scored.append((entry, score)) }
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.alias < $1.0.alias }
            results = scored.map(\.0)
            last = query
            final = results.count
        }
        return (Date().timeIntervalSince(start) * 1000, final)
    }

    func testIndexCoversTheWholeFleet() {
        XCTAssertEqual(SearchPerformanceTests.fleet.count, 249)
    }

    func testTypingStaysImperceptible() {
        let full = timeTyping("payments-prod-web", incremental: false)
        let incremental = timeTyping("payments-prod-web", incremental: true)
        XCTAssertLessThan(full.ms, 25.0, String(format: "%.2f ms", full.ms))
        XCTAssertLessThan(full.ms / 15.0, 2.0, "per keystroke")
        XCTAssertLessThanOrEqual(incremental.ms, full.ms + 1.0,
                                 "narrowing must not be slower than a full rescan")
        XCTAssertEqual(full.count, incremental.count,
                       "both strategies must agree on the result set")
    }
}
