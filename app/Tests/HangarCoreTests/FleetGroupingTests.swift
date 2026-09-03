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

/// What a level does depends on where it sits. This is the number that would
/// have said "env_name is a poor third level" before anyone tried it.
final class LevelReportTests: XCTestCase {
    private func host(_ product: String, _ env: String, _ envName: String = "",
                      id: String) -> Instance {
        var tags = ["product": product, "env": env, "Name": "web"]
        if !envName.isEmpty { tags["env_name"] = envName }
        return Fixture.instance(tags, id: id)
    }

    /// Two product+env groups. One has an env_name on a single host, the other
    /// has none at all, which is the shape a real fleet had.
    private var fleet: [Instance] {
        [host("screen", "prod", "repl", id: "i-0"),
         host("screen", "prod", id: "i-1"),
         host("screen", "prod", id: "i-2"),
         host("collect", "uat", id: "i-3"),
         host("collect", "uat", id: "i-4")]
    }

    func testALevelEveryHostCarriesReadsClean() {
        let reports = FleetGrouping.report(fleet, groupBy: ["product", "env", "env_name"])
        XCTAssertEqual(reports[0].key, "product")
        XCTAssertEqual(reports[0].hosts, 5)
        XCTAssertEqual(reports[0].groups, 2)
        XCTAssertEqual(reports[0].withoutValue, 0)
        XCTAssertFalse(reports[0].isMostlyEmpty)
    }

    func testAnOptionalLevelCountsBothWaysOfHavingNoValue() {
        let reports = FleetGrouping.report(fleet, groupBy: ["product", "env", "env_name"])
        let envName = reports[2]
        XCTAssertEqual(envName.hosts, 5, "every host reaches the third level")
        // collect/uat skips it entirely (2 hosts); screen/prod draws it with two
        // of its three hosts in the untagged group.
        XCTAssertEqual(envName.withoutValue, 4)
        XCTAssertEqual(envName.groups, 2, "repl and untagged, in the one scope that has it")
        XCTAssertTrue(envName.isMostlyEmpty, "it does nothing for four hosts in five")
    }

    func testTheSameKeyReadsDifferentlyHigherUpTheCascade() {
        let deep = FleetGrouping.report(fleet, groupBy: ["product", "env", "env_name"])[2]
        let shallow = FleetGrouping.report(fleet, groupBy: ["env_name"])[0]
        XCTAssertEqual(shallow.groups, 2, "one scope, so repl and untagged")
        XCTAssertEqual(deep.groups, shallow.groups)
        XCTAssertEqual(deep.withoutValue, 4)
        XCTAssertEqual(shallow.withoutValue, 4)
    }

    func testAppendingIsAnsweredWithoutCommittingToIt() {
        let current = ["product", "env"]
        let preview = FleetGrouping.reportAppending("env_name", to: current, in: fleet)
        XCTAssertEqual(preview.key, "env_name")
        XCTAssertTrue(preview.isMostlyEmpty)
        XCTAssertEqual(FleetGrouping.report(fleet, groupBy: current).count, 2,
                       "asking did not change the configured levels")
    }

    func testAKeyNobodyCarriesIsEmptyEverywhere() {
        let preview = FleetGrouping.reportAppending("Team", to: ["product"], in: fleet)
        XCTAssertEqual(preview.groups, 0, "never drawn, so it makes no groups")
        XCTAssertEqual(preview.withoutValue, preview.hosts)
    }
}
