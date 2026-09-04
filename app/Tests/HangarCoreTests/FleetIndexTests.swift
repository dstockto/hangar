import XCTest
@testable import HangarCore

/// The panel and the `hangar` command both search through here. Mistake 18 was
/// two things answering one question differently, and "which host matches this"
/// is a question a menubar and a shell must not answer differently.
final class FleetIndexTests: XCTestCase {

    private func host(_ product: String, _ env: String, _ role: String,
                      id: String = "i-0123456789abcdef0",
                      hostname: String? = "host.example.com") -> Instance {
        var tags = ["product": product, "env": env, "Name": role]
        if let hostname { tags["hostname"] = hostname }
        return Instance(id: id, state: "running", type: "t3.small",
                        privateIP: "10.0.0.1", publicIP: nil,
                        availabilityZone: "us-west-2a",
                        launchTime: "2026-08-20T15:46:42.000Z", tags: tags)
    }

    private var config: HangarConfig { .standard() }

    func testEveryHostGetsTheAliasSSHActuallyResolves() {
        let entries = FleetIndex.entries(
            for: [host("payments", "prod", "web")], config: config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].alias, "payments-prod-web")
    }

    /// An empty string sorts first, so untagged hosts used to open the list.
    func testUntaggedHostsSortToTheEndRatherThanTheFront() {
        let entries = FleetIndex.entries(for: [
            host("", "", "orphan", id: "i-000000000000000ff"),
            host("payments", "prod", "web", id: "i-0000000000000000a"),
        ], config: config)
        XCTAssertEqual(entries.first?.instance.product, "payments")
        XCTAssertEqual(entries.last?.instance.role, "orphan")
    }

    func testRankingPutsTheBestMatchFirst() {
        let entries = FleetIndex.entries(for: [
            host("payments", "prod", "database", id: "i-0000000000000000a"),
            host("payments", "prod", "web", id: "i-0000000000000000b"),
            host("shipping", "qa", "web", id: "i-0000000000000000c"),
        ], config: config)
        let ranked = FleetIndex.ranked(entries, matching: Fuzzy.Query("payments web"))
        XCTAssertEqual(ranked.first?.alias, "payments-prod-web")
        XCTAssertFalse(ranked.contains { $0.alias == "payments-prod-database" },
                       "every token has to match somewhere")
    }

    /// Two runs of one search list the same hosts in the same order, which is
    /// what makes `hangar -a -s web | head -1` safe to put in a script.
    func testRankingIsStableAcrossRuns() {
        let entries = FleetIndex.entries(for: [
            host("payments", "prod", "web", id: "i-0000000000000000a"),
            host("payments", "qa", "web", id: "i-0000000000000000b"),
            host("payments", "dev", "web", id: "i-0000000000000000c"),
        ], config: config)
        let first = FleetIndex.ranked(entries, matching: Fuzzy.Query("web"))
        let second = FleetIndex.ranked(entries, matching: Fuzzy.Query("web"))
        XCTAssertEqual(first.map(\.alias), second.map(\.alias))
    }

    func testAnEmptyQueryIsTheWholeFleetInMenuOrder() {
        let entries = FleetIndex.entries(for: [
            host("payments", "prod", "web", id: "i-0000000000000000a"),
            host("shipping", "qa", "web", id: "i-0000000000000000b"),
        ], config: config)
        XCTAssertEqual(FleetIndex.ranked(entries, matching: Fuzzy.Query("")).map(\.alias),
                       entries.map(\.alias))
    }

    func testFilteringUsesTheSameWildcardsAsTheHotkeys() {
        let entries = FleetIndex.entries(for: [
            host("payments", "prod", "web", id: "i-0000000000000000a"),
            host("payments", "qa", "web", id: "i-0000000000000000b"),
        ], config: config)
        XCTAssertEqual(FleetIndex.filtered(entries, by: ["env": "prod"]).count, 1)
        XCTAssertEqual(FleetIndex.filtered(entries, by: ["env": "p*"]).count, 1)
        XCTAssertEqual(FleetIndex.filtered(entries, by: nil).count, 2)
    }
}

/// The cache is what the command line reads, so its format is a contract now
/// rather than an implementation detail of the app.
final class FleetCacheTests: TemporaryDirectoryTestCase {

    private func cache() -> FleetCache {
        FleetCache(
            instances: [Fixture.instance(["product": "payments", "env": "prod",
                                          "Name": "web"])],
            region: "us-west-2", fetchedAt: Date(timeIntervalSince1970: 1_756_000_000),
            tagCatalog: nil, history: [FleetSample(at: Date(), hosts: 1)])
    }

    func testItRoundTrips() throws {
        let path = self.path("cache")
        XCTAssertTrue(cache().write(to: path))
        let read = try XCTUnwrap(FleetCache.load(path: path))
        XCTAssertEqual(read.region, "us-west-2")
        XCTAssertEqual(read.instances.count, 1)
        XCTAssertEqual(read.instances.first?.product, "payments")
        XCTAssertEqual(read.history?.count, 1)
    }

    /// The cache is the whole inventory: ids, private addresses, every tag.
    func testItIsWrittenPrivate() throws {
        let path = self.path("cache")
        XCTAssertTrue(cache().write(to: path))
        let mode = try FileManager.default
            .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    /// A Hangar that has never refreshed is not an error, and the caller says
    /// what it means better than the loader can.
    func testAMissingCacheIsNilRatherThanACrash() {
        XCTAssertNil(FleetCache.load(path: path("nothing-here")))
    }

    func testAgeIsMeasuredFromTheFetch() {
        let old = FleetCache(instances: [], region: "us-west-2",
                             fetchedAt: Date().addingTimeInterval(-7200))
        XCTAssertEqual(old.age, 7200, accuracy: 5)
    }
}
