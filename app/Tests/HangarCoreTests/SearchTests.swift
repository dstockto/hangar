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

    /// What `SSHConfigImport` produces for an apex name: product and role both
    /// come from its first label, so the two fields hold the same string.
    /// `SSHConfigImportTests` pins that derivation against the real importer.
    private let imported = SearchEntry(instance: Fixture.instance([
        "product": "webstore", "Name": "webstore",
        "hostname": "webstore.example"]), alias: "webstore.example")

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
        XCTAssertFalse(matches("pdw", entry),
                       "0034 closed this: one letter from each of three fields, "
                       + "naming none of them, is the roaming the label rule bans")
        XCTAssertTrue(matches("ppw", entry),
                      "the acronym survives, because every letter is a label initial")
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
        // The query is a separator-bearing alias, so this also pins that one
        // matches at all: agreeing on zero hid a regression that matched nothing.
        XCTAssertGreaterThan(full.count, 0, "the typed alias has to find its host")
    }
}

/// A token used to be free to take one letter from a role and the next from the
/// region three labels later, which on a fleet whose names carry six labels each
/// matched every host in the product. Names here are placeholders in the shape
/// `role.env.product.example.com`, chosen so the derivation below reproduces:
/// `torque` holds the `q`, and no `a` follows it in either the alias or the tags.
final class RoamingTokenSearchTests: XCTestCase {

    private func fleet() -> [SearchEntry] {
        func host(_ alias: String, _ hostname: String, env: String,
                  envName: String = "") -> SearchEntry {
            var tags = ["product": "payments", "env": env, "Name": "torque",
                        "hostname": hostname]
            if !envName.isEmpty { tags["env_name"] = envName }
            return SearchEntry(instance: Fixture.instance(tags), alias: alias)
        }
        return [
            host("payments-qa-torque", "torque.qa.payments.example.com", env: "qa"),
            // The autoscaled pair carry an instance-id label in the hostname, which
            // is 19 more characters for a token to roam through.
            host("payments-prod-torque-1",
                 "i-0000000000000f264.torque.prod.payments.example.com", env: "prod"),
            host("payments-prod-torque-2",
                 "i-0000000000000abe0.torque.prod.payments.example.com", env: "prod"),
            host("payments-uat-torque-1",
                 "i-0000000000000cad5.torque.uat.payments.example.com", env: "uat"),
            host("payments-dev-dev1-torque", "dev1.torque.dev.payments.example.com",
                 env: "dev", envName: "dev1"),
        ]
    }

    private func matching(_ query: String) -> [String] {
        FleetIndex.ranked(fleet(), matching: Fuzzy.Query(query)).map(\.alias)
    }

    /// The reported case: three terms that name exactly one host, and a menu.
    func testEveryTermNamesTheSameOneHost() {
        XCTAssertEqual(matching("payments qa torque"), ["payments-qa-torque"])
    }

    /// Why the other four used to come along. `qa` is in no label of theirs; it
    /// took `q` from `torque` and `a` from `payments` a label later.
    func testTheStrayTermMatchesNoOtherHost() {
        let prod = fleet()[1]
        XCTAssertNil(prod.score(for: Fuzzy.Query("qa")))
        XCTAssertNotNil(prod.score(for: Fuzzy.Query("payments")),
                        "the terms that do name it are untouched")
        XCTAssertNotNil(prod.score(for: Fuzzy.Query("torque")))
    }

    /// The instance-id label is 19 characters of hex sitting in a searchable
    /// hostname, which is 19 more characters for a token to roam through.
    func testATokenDoesNotRoamThroughAnInstanceId() {
        let prod = fleet()[1]
        XCTAssertNotNil(prod.score(for: Fuzzy.Query("f264")),
                        "inside the id is still a label, and still findable")
        XCTAssertNotNil(prod.score(for: Fuzzy.Query("f264torque")),
                        "straight through the dot is the same rule as paymentsprod")
        XCTAssertNil(prod.score(for: Fuzzy.Query("f2torque")),
                     "but skipping characters on the way out of the id is roaming")
    }

    /// Narrowing, the property 0030 was about, now holds a character further in.
    func testTypingMoreKeepsNarrowing() {
        XCTAssertEqual(matching("torque").count, 5)
        XCTAssertEqual(matching("payments torque").count, 5)
        XCTAssertEqual(matching("payments torque qa").count, 1)
        // A bare `q` is inside `torque` on all five and narrows nothing, which is
        // honest: it is the second character that first names one host.
        XCTAssertEqual(matching("torque q").count, 5)
    }
}

/// Three ways a token can be anchored to a name, and the roaming that is left
/// over once they are the only three.
final class AnchoredTokenTests: XCTestCase {

    private let hay = Fuzzy.lowered("payments-prod-web-1")

    private func admits(_ token: String) -> Bool {
        Fuzzy.admits(Fuzzy.lowered(token), in: hay)
    }

    func testInsideOneLabel() {
        XCTAssertTrue(admits("pay"))
        XCTAssertTrue(admits("pymnts"), "a subsequence of one label is still fuzzy")
        XCTAssertTrue(admits("web"))
    }

    /// 0030 kept per-field scoring out partly because it would have dropped this,
    /// so the rule that replaced it has to keep it.
    func testTypedStraightThroughTheSeparators() {
        XCTAssertTrue(admits("paymentsprod"))
        XCTAssertTrue(admits("prodweb"))
        XCTAssertFalse(admits("paymentsweb"), "straight through means contiguous")
    }

    func testLabelInitials() {
        XCTAssertTrue(admits("ppw"), "the docblock's own example")
        XCTAssertTrue(admits("pw"))
        XCTAssertFalse(admits("pdw"), "d is in the middle of prod, not the start")
    }

    func testRoamingIsWhatIsLeft() {
        XCTAssertFalse(admits("ysod"), "one letter from payments, three from prod")
        XCTAssertFalse(admits("mw"))
    }

    /// The three routes are asked of the name as written, so pin what the name
    /// actually offers each of them: four labels, the initials `ppw1`, and the
    /// whole thing read straight through its separators.
    func testTheNameOffersEachRouteSomethingDifferent() {
        for label in ["payments", "prod", "web", "1"] {
            XCTAssertTrue(admits(label), "\(label) is a label of this name")
        }
        XCTAssertTrue(admits("ppw1"), "the initials an acronym reads")
        XCTAssertTrue(admits("paymentsprodweb1"),
                      "and the name read straight through its separators")
        XCTAssertFalse(admits("paymentsweb1"), "which is not the same as skipping one")
    }
}

/// A highlight is the only account of itself the search gives, so it answers the
/// same question the score does. It used to be able to paint nothing at all for a
/// term that had qualified the host.
final class HighlightAgreesWithScoreTests: XCTestCase {

    private func marked(_ query: String, _ candidate: String) -> String {
        let ranges = Fuzzy.ranges(query: Fuzzy.Query(query), in: candidate)
        var marks = [Character](repeating: " ", count: candidate.count)
        for range in ranges {
            let lower = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let upper = candidate.distance(from: candidate.startIndex, to: range.upperBound)
            for i in lower..<upper { marks[i] = "^" }
        }
        return String(marks)
    }

    /// The term that qualified six hosts and painted two characters, one of them
    /// underneath another term's highlight. Now it qualifies nothing and paints
    /// nothing, which is the same answer twice rather than two answers.
    func testARoamingTermPaintsNothingBecauseItMatchesNothing() {
        XCTAssertEqual(marked("qa", "torque.prod.payments.example.com"),
                       "                                ")
    }

    /// A term that fits inside one label underlines that label, rather than
    /// scattering itself from there to the end of the domain.
    func testAMatchIsConfinedToTheLabelItMatched() {
        XCTAssertEqual(marked("tore", "torque.prod.payments.example.com"),
                       "^^^  ^                          ")
    }

    func testAnAcronymStillPaintsAcrossTheWholeName() {
        XCTAssertEqual(marked("ppw", "payments-prod-web"),
                       "^        ^    ^  ")
    }

    func testEveryTermStillGetsItsOwnRanges() {
        XCTAssertEqual(marked("payments web", "payments-prod-web"),
                       "^^^^^^^^      ^^^")
    }
}

/// A typed separator is punctuation in the name, not part of a word. Every alias
/// the menu displays carries one, so a query that repeats what is on screen has
/// to match the row it was read from.
final class SeparatorBearingQueryTests: XCTestCase {

    private let entry = SearchEntry(instance: Fixture.instance([
        "product": "payments", "env": "prod", "Name": "web",
        "hostname": "web.prod.payments.example.com"]), alias: "payments-prod-web-1")

    private func matches(_ query: String) -> Bool {
        entry.score(for: Fuzzy.Query(query)) != nil
    }

    func testTypingTheAliasTheMenuShowsFindsIt() {
        XCTAssertTrue(matches("payments-prod-web-1"))
        XCTAssertTrue(matches("payments-prod"))
        XCTAssertTrue(matches("db-prod") == false, "a different host is still a miss")
    }

    func testADottedNameMatchesItself() {
        let imported = SearchEntry(instance: Fixture.instance([
            "Name": "workers", "hostname": "workers.example"]), alias: "workers.example")
        XCTAssertTrue(imported.score(for: Fuzzy.Query("workers.example")) != nil)
        XCTAssertTrue(imported.score(for: Fuzzy.Query("workers")) != nil)
    }

    /// `hostname` falls back to the private IP and then the instance id, so both
    /// of those are things a person types with separators in them.
    func testAnAddressMatchesItself() {
        // No hostname tag, so `host` falls back to the private IP the fixture sets.
        let bare = SearchEntry(instance: Fixture.instance(["Name": "db"]), alias: "db-1")
        XCTAssertNotNil(bare.score(for: Fuzzy.Query("10.0.0.1")))
        XCTAssertEqual(bare.hostname, "10.0.0.1", "the fallback this covers")
    }

    /// The third fallback, which `Fixture.instance` cannot reach because it always
    /// sets a private IP. An id is the one name a host can never not have.
    func testAnInstanceIdMatchesItself() {
        let idOnly = Instance(id: "i-0a1b2c3d4e5f60718", state: "running",
                              type: "t3.small", privateIP: nil, publicIP: nil,
                              availabilityZone: nil,
                              launchTime: "2026-08-20T15:46:42.000Z",
                              tags: ["Name": "db"])
        let entry = SearchEntry(instance: idOnly, alias: "db-1")
        XCTAssertEqual(entry.hostname, "i-0a1b2c3d4e5f60718",
                       "neither a hostname tag nor an address, so the id is the name")
        XCTAssertNotNil(entry.score(for: Fuzzy.Query("i-0a1b")))
        XCTAssertNotNil(entry.score(for: Fuzzy.Query("i-0a1b2c3d4e5f60718")))
        XCTAssertNil(entry.score(for: Fuzzy.Query("i-0b1a")), "still not roaming")
    }

    /// Folding the separator out must not reopen roaming: it is dropped from the
    /// token, not turned into a licence to cross labels.
    func testFoldingTheSeparatorDoesNotReopenRoaming() {
        XCTAssertFalse(matches("q-a"))
        XCTAssertFalse(matches("p-d-w"))
        XCTAssertTrue(matches("p-p-w"), "still an acronym once the dashes go")
    }
}
