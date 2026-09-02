import XCTest
@testable import HangarCore

/// The shape of the menubar cascade. A fleet that groups by one thing must get
/// one level, not one real level and two empty ones, and a fleet that wants to
/// group by something Hangar has never heard of must be able to say so.
final class FleetGroupingTests: XCTestCase {

    private func hosts(_ tagSets: [[String: String]]) -> [Instance] {
        tagSets.enumerated().map { index, tags in
            Fixture.instance(tags, id: "i-0\(String(format: "%015x", index))")
        }
    }

    private func titles(_ nodes: [FleetGrouping.Node]) -> [String] {
        nodes.compactMap {
            if case .group(let title, _) = $0 { return title } else { return nil }
        }
    }

    private func hostCount(_ nodes: [FleetGrouping.Node]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .host: return total + 1
            case .group(_, let children): return total + hostCount(children)
            }
        }
    }

    private func depthOf(_ nodes: [FleetGrouping.Node]) -> Int {
        var deepest = 0
        for node in nodes {
            if case .group(_, let children) = node {
                deepest = max(deepest, 1 + depthOf(children))
            }
        }
        return deepest
    }

    // MARK: - Levels a fleet does not use

    func testOneGroupingProducesOneLevel() {
        // Regression: env and env_name were still rendered, so the menu had a
        // level containing a single "untagged" entry containing everything.
        let fleet = hosts([
            ["product": "payments", "Name": "web"],
            ["product": "payments", "Name": "db"],
            ["product": "shop", "Name": "web"],
        ])
        let tree = FleetGrouping.tree(fleet)
        XCTAssertEqual(titles(tree), ["payments", "shop"])
        XCTAssertEqual(depthOf(tree), 1, "one grouping, one level")
        XCTAssertEqual(hostCount(tree), 3)
        XCTAssertEqual(FleetGrouping.depth(fleet), 1)
    }

    func testNoGroupingAtAllProducesAFlatList() {
        let fleet = hosts([["Name": "bastion"], ["Name": "jump"]])
        let tree = FleetGrouping.tree(fleet)
        XCTAssertTrue(titles(tree).isEmpty, "no groups")
        XCTAssertEqual(depthOf(tree), 0)
        XCTAssertEqual(hostCount(tree), 2)
    }

    func testTwoGroupingsNest() {
        let fleet = hosts([
            ["product": "payments", "env": "prod", "Name": "web"],
            ["product": "payments", "env": "qa", "Name": "web"],
        ])
        let tree = FleetGrouping.tree(fleet)
        XCTAssertEqual(titles(tree), ["payments"])
        XCTAssertEqual(depthOf(tree), 2)
        XCTAssertEqual(hostCount(tree), 2)
    }

    func testAPartlyTaggedLevelKeepsAnUntaggedBucket() {
        // Some hosts have the tag and some do not: the level is real and the
        // ones without it need somewhere to go.
        let fleet = hosts([
            ["product": "payments", "Name": "web"],
            ["Name": "orphan"],
        ])
        XCTAssertEqual(titles(FleetGrouping.tree(fleet)), ["payments", "untagged"])
    }

    // MARK: - Levels the user composes

    func testAnyTagKeyCanBeALevel() {
        // A fleet that organises by team and region, neither of which Hangar
        // maps to anything.
        let fleet = hosts([
            ["Team": "platform", "Region": "emea", "Name": "web"],
            ["Team": "platform", "Region": "apac", "Name": "web"],
            ["Team": "data", "Region": "emea", "Name": "etl"],
        ])
        let tree = FleetGrouping.tree(fleet, groupBy: ["Team", "Region"])
        XCTAssertEqual(titles(tree), ["data", "platform"])
        XCTAssertEqual(depthOf(tree), 2)
        XCTAssertEqual(hostCount(tree), 3)
    }

    func testLevelOrderIsTheOrderGiven() {
        let fleet = hosts([
            ["Team": "platform", "Region": "emea", "Name": "web"],
            ["Team": "data", "Region": "emea", "Name": "etl"],
        ])
        XCTAssertEqual(titles(FleetGrouping.tree(fleet, groupBy: ["Region", "Team"])),
                       ["emea"], "region first means one region group at the top")
        XCTAssertEqual(titles(FleetGrouping.tree(fleet, groupBy: ["Team", "Region"])),
                       ["data", "platform"])
    }

    func testAnEmptyLevelListIsAFlatList() {
        let fleet = hosts([
            ["product": "payments", "env": "prod", "Name": "web"],
            ["product": "shop", "env": "prod", "Name": "db"],
        ])
        let tree = FleetGrouping.tree(fleet, groupBy: [])
        XCTAssertTrue(titles(tree).isEmpty)
        XCTAssertEqual(hostCount(tree), 2)
    }

    func testAConfiguredLevelNoHostCarriesAddsNoLevel() {
        let fleet = hosts([["Team": "platform", "Name": "web"]])
        XCTAssertEqual(FleetGrouping.depth(fleet, groupBy: ["Team", "CostCentre"]), 1,
                       "the configured list is two, the produced menu is one")
        XCTAssertEqual(depthOf(FleetGrouping.tree(fleet, groupBy: ["Team", "CostCentre"])), 1)
    }

    func testCanonicalAndRawKeysBothWorkAsLevels() {
        // "env" is canonical; "Environment" is what the fleet actually carries.
        let fleet = [TagMapping.standard.normalize(
            Fixture.instance(["Environment": "prod", "Name": "web"]))]
        XCTAssertEqual(titles(FleetGrouping.tree(fleet, groupBy: ["env"])), ["prod"])
        XCTAssertEqual(titles(FleetGrouping.tree(fleet, groupBy: ["Environment"])), ["prod"])
    }

    func testEveryHostSurvivesWhateverTheLevels() {
        let fleet = hosts((0..<40).map { i in
            ["Team": ["a", "b"][i % 2], "Region": ["x", "y", "z"][i % 3],
             "Name": "host-\(i)"]
        })
        for keys in [[], ["Team"], ["Team", "Region"], ["Region", "Team"],
                     ["Team", "Region", "Nonexistent"]] {
            XCTAssertEqual(hostCount(FleetGrouping.tree(fleet, groupBy: keys)), 40,
                           "lost a host with levels \(keys)")
        }
    }

    // MARK: - Config

    func testTheDefaultLevelsPreserveTheOriginalBehaviour() {
        XCTAssertEqual(FleetGrouping.defaultLevels, ["product", "env", "env_name"])
        XCTAssertEqual(HangarConfig.standard().groupingKeys,
                       FleetGrouping.defaultLevels)
    }

    func testAConfigPredatingLevelsStillGroups() throws {
        let older = Data("{\"refresh_minutes\":30}".utf8)
        let decoded = try JSONDecoder().decode(HangarConfig.self, from: older)
        XCTAssertNil(decoded.groupBy)
        XCTAssertEqual(decoded.groupingKeys, FleetGrouping.defaultLevels)
    }

    func testAnEmptyListRoundTripsAsADeliberateChoice() throws {
        var config = HangarConfig.standard()
        config.groupBy = []
        let decoded = try JSONDecoder().decode(
            HangarConfig.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded.groupingKeys, [], "empty means flat, not unset")
    }
}
