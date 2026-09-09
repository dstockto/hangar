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

/// A repeated field used to appear twice in the metadata haystack, so a query
/// could take some of its characters from one copy and the rest from the next.
/// That produced matches no single field could produce, and typing more stopped
/// narrowing the list.
final class DuplicateMetadataSearchTests: XCTestCase {

    /// What `SSHConfigImport` produces: product and role both come from the host
    /// name, so the two fields hold the same string.
    private let imported = SearchEntry(instance: Fixture.instance([
        "product": "webstore", "Name": "webstore",
        "hostname": "webstore.example.com"]), alias: "webstore.example.com")

    private func matches(_ query: String, _ entry: SearchEntry) -> Bool {
        entry.score(for: Fuzzy.Query(query)) != nil
    }

    func testTheHaystackHoldsARepeatedValueOnce() {
        XCTAssertEqual(imported.metadata, "webstore")
    }

    /// `wer` is an honest subsequence of `webstore`. `wers` is not, and could only
    /// ever have matched by taking its `s` from a second copy of the same value.
    func testTypingMoreNarrows() {
        XCTAssertTrue(matches("wer", imported),
                      "an honest subsequence of the name, and no longer surprising")
        XCTAssertFalse(matches("wers", imported),
                       "only the doubled haystack could match this")
        XCTAssertFalse(matches("wersw", imported),
                       "and adding a character has to keep dropping it")
    }

    func testRealMatchesSurvive() {
        XCTAssertTrue(matches("web", imported))
        XCTAssertTrue(matches("store", imported))
        XCTAssertTrue(matches("wstore", imported))
    }

    /// The haystack is lowercased before it is searched, so `Web` and `web` double
    /// it just as surely as two identical spellings do.
    func testDuplicatesCollapseRegardlessOfCase() {
        let entry = SearchEntry(instance: Fixture.instance([
            "product": "Web", "Name": "web", "hostname": "web.example.com"]),
            alias: "web-1")
        XCTAssertEqual(entry.metadata, "Web", "the first spelling is the one kept")
        XCTAssertFalse(matches("webw", entry))
    }

    /// Cross-field search is the point of this field, and only the repeated value
    /// collapses. Four distinct tags stay four.
    func testDistinctFieldsAreUntouched() {
        let entry = SearchEntry(instance: Fixture.instance([
            "product": "payments", "env": "prod", "env_name": "prod-1",
            "Name": "web", "hostname": "web.prod.payments.example.com"]),
            alias: "payments-prod-web-1")
        XCTAssertEqual(entry.metadata, "payments prod prod-1 web")
        XCTAssertTrue(matches("payments web", entry))
        XCTAssertTrue(matches("pdw", entry), "one token may still span two fields")
    }

    /// `Fuzzy.lowered` folds ASCII only, so these two are different bytes to the
    /// search and both have to stay: collapsing them would leave the lowercase
    /// spelling in no field at all, and a host you can name is a host you can find.
    func testDedupeIsNeverWiderThanTheSearch() {
        let entry = SearchEntry(instance: Fixture.instance([
            "product": "\u{00DC}ber", "Name": "\u{00FC}ber",
            "hostname": "uber.example.com"]), alias: "uber-1")
        XCTAssertEqual(entry.metadata, "\u{00DC}ber \u{00FC}ber")
        XCTAssertTrue(matches("\u{00FC}ber", entry),
                      "the lowercase spelling still finds the host")
    }

    /// An EC2 host tagged `product=web` with `Name=web` had the same haystack as
    /// an imported one, so the fix cannot key on where the host came from.
    func testTheFixIsNotAboutTheSource() {
        let entry = SearchEntry(instance: Fixture.instance([
            "product": "web", "env": "prod", "Name": "web",
            "hostname": "i-0123456789abcdef0.example.com"]), alias: "web-prod-1")
        XCTAssertEqual(entry.metadata, "web prod")
        XCTAssertFalse(matches("wpb", entry))
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

    /// The landing page claims search stays under a millisecond per keystroke at
    /// ten thousand hosts. That is measured on a release build, which is what
    /// ships; this suite runs unoptimized and is roughly an order of magnitude
    /// slower, so an absolute threshold here would either be meaningless or
    /// wrong. What matters and what a refactor can actually break is the shape
    /// of the curve, so this asserts that instead: forty times the hosts must
    /// not cost more than sixty times the work.
    func testSearchScalesLinearlyWithFleetSize() {
        func fleet(_ count: Int) -> [SearchEntry] {
            let products = ["payments", "search", "media", "identity", "billing",
                            "infra", "risk", "shop"]
            let envs = ["prod", "qa", "uat", "sb", "dev"]
            let roles = ["web", "db", "etl", "xfer", "worker", "scheduler",
                         "reports", "ci", "grafana", "cache"]
            return (0..<count).map { i in
                let role = roles[i % roles.count]
                let env = envs[i % envs.count]
                let product = products[i % products.count]
                let id = "i-0\(String(format: "%015x", i))"
                let instance = Fixture.instance(
                    ["product": product, "env": env, "Name": role,
                     "hostname": "\(id).\(role).\(env).\(product).example.com"], id: id)
                return SearchEntry(instance: instance, alias: instance.aliasStem + "-\(i)")
            }
        }

        func typeOut(_ query: String, _ pool: [SearchEntry]) -> Double {
            var results = pool
            var last = ""
            let start = Date()
            for end in 1...query.count {
                let typed = String(query.prefix(end))
                let needle = Fuzzy.Query(typed)
                let source = (typed.hasPrefix(last) && !last.isEmpty) ? results : pool
                var scored: [(SearchEntry, Int)] = []
                scored.reserveCapacity(source.count)
                for entry in source {
                    if let score = entry.score(for: needle) { scored.append((entry, score)) }
                }
                scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.alias < $1.0.alias }
                results = scored.map(\.0)
                last = typed
            }
            return Date().timeIntervalSince(start) * 1000
        }

        let small = fleet(250)
        let large = fleet(10_000)
        _ = typeOut("payments prod web", small)   // warm the caches
        _ = typeOut("payments prod web", large)

        let smallMs = typeOut("payments prod web", small)
        let largeMs = typeOut("payments prod web", large)
        let ratio = largeMs / max(smallMs, 0.0001)

        XCTAssertLessThan(ratio, 60.0,
                          String(format: "40x the hosts cost %.1fx the time (%.2f ms vs %.2f ms)",
                                 ratio, largeMs, smallMs))
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
