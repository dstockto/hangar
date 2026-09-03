import XCTest
@testable import HangarCore

/// Drilling asks one question at each level: which hosts am I now looking at.
final class ClusterFocusTests: XCTestCase {
    private let keys = ["product", "env"]

    private func host(_ product: String, _ env: String, _ name: String = "web",
                      id: String = "i-0000000000000000a", team: String = "core",
                      envName: String = "") -> Instance {
        var tags = ["product": product, "env": env, "Name": name, "Team": team]
        if !envName.isEmpty { tags["env_name"] = envName }
        return Fixture.instance(tags, id: id)
    }

    private func enter(_ focus: ClusterFocus, _ value: String,
                       keys: [String]? = nil) -> ClusterFocus {
        let list = keys ?? self.keys
        let level = focus.path.last.map { $0.level + 1 } ?? 0
        return focus.entering(level: level, key: list[level], value: value)
    }

    func testTheFleetShowsEverything() {
        let all = [host("payments", "prod"), host("billing", "dev")]
        XCTAssertEqual(ClusterFocus.fleet.filter(all).count, 2)
        XCTAssertEqual(ClusterFocus.fleet.label, "")
        XCTAssertTrue(ClusterFocus.fleet.isFleet)
    }

    func testEnteringTheFirstLevelKeepsEveryEnvironmentUnderIt() {
        let all = [host("payments", "prod"), host("payments", "stage"),
                   host("billing", "prod")]
        let focus = enter(.fleet, "payments")
        XCTAssertEqual(focus.filter(all).count, 2)
        XCTAssertEqual(focus.label, "payments")
    }

    func testEnteringTheSecondLevelNarrowsToOneGroup() {
        let all = [host("payments", "prod"), host("payments", "stage"),
                   host("billing", "prod")]
        let focus = enter(enter(.fleet, "payments"), "prod")
        XCTAssertEqual(focus.filter(all).count, 1)
        XCTAssertEqual(focus.label, "payments · prod")
    }

    func testOpeningAHostNarrowsToThatOneInstance() {
        let all = [host("payments", "prod", "web", id: "i-0000000000000000a"),
                   host("payments", "prod", "web", id: "i-0000000000000000b")]
        let focus = enter(enter(.fleet, "payments"), "prod")
            .opening(host: "i-0000000000000000b")
        XCTAssertEqual(focus.filter(all).map(\.id), ["i-0000000000000000b"])
    }

    func testLeavingUndoesOneLevelAtATime() {
        let opened = enter(enter(.fleet, "payments"), "prod").opening(host: "i-0")
        let group = opened.leaving()
        XCTAssertNil(group.hostID)
        XCTAssertEqual(group.label, "payments · prod")
        XCTAssertEqual(group.leaving().label, "payments")
        XCTAssertTrue(group.leaving().leaving().isFleet)
        XCTAssertTrue(ClusterFocus.fleet.leaving().isFleet, "the fleet is the floor")
    }

    func testBackNamesWhereItGoesAtEveryDepth() {
        XCTAssertNil(ClusterFocus.fleet.backDestination,
                     "the fleet has nowhere further out, so nothing offers a way there")
        let product = enter(.fleet, "payments")
        XCTAssertEqual(product.backDestination, "", "back from a product is the fleet")
        let env = enter(product, "prod")
        XCTAssertEqual(env.backDestination, "payments")
        XCTAssertEqual(env.opening(host: "i-0").backDestination, "payments · prod",
                       "an open host steps back to the group it was in")
    }

    func testTheNextLevelComesFromTheConfiguredKeys() {
        let all = [host("payments", "prod"), host("billing", "dev")]
        XCTAssertEqual(ClusterFocus.fleet.nextLevel(keys, among: all)?.key, "product")
        XCTAssertEqual(enter(.fleet, "payments").nextLevel(keys, among: all)?.key, "env")
        XCTAssertNil(enter(enter(.fleet, "payments"), "prod").nextLevel(keys, among: all),
                     "below the last level are hosts, not another group")
    }

    func testItFollowsTheConfiguredGroupingRatherThanTheDefaults() {
        let all = [host("payments", "prod", team: "core"),
                   host("billing", "prod", team: "core"),
                   host("edge", "prod", team: "edge")]
        let focus = ClusterFocus.fleet.entering(level: 0, key: "Team", value: "core")
        XCTAssertEqual(focus.filter(all).count, 2)
    }

    // MARK: - Levels nobody carries
    //
    // env_name is optional, and on a real fleet about a third of hosts have one.
    // A group where none of them do must not gain a level containing a single
    // "untagged" circle: it costs a click and says nothing, which is the rule
    // FleetGrouping already applies to the menubar cascade.

    private let three = ["product", "env", "env_name"]

    func testALevelNoHostInScopeCarriesIsSkipped() {
        let all = [host("collect", "uat", "web", id: "i-0"),
                   host("collect", "uat", "api", id: "i-1")]
        let focus = enter(enter(.fleet, "collect", keys: three), "uat", keys: three)
        XCTAssertNil(focus.nextLevel(three, among: focus.filter(all)),
                     "no host here has an env_name, so the next thing down is the hosts")
    }

    func testALevelSomeHostsCarryIsStillShown() {
        let all = [host("screen", "prod", "web", id: "i-0"),
                   host("screen", "prod", "web", id: "i-1", envName: "blue")]
        let focus = enter(enter(.fleet, "screen", keys: three), "prod", keys: three)
        XCTAssertEqual(focus.nextLevel(three, among: focus.filter(all))?.key, "env_name",
                       "one host carrying it is enough for the level to mean something")
    }

    func testSkippingALevelDoesNotMisalignTheOnesAfterIt() {
        // Configured product, env_name, env. Nothing carries env_name, so the
        // second level drawn is env, and the path has to remember that or the
        // filter compares the env value against the env_name key.
        let order = ["product", "env_name", "env"]
        let all = [host("collect", "prod", id: "i-0"), host("collect", "dev", id: "i-1")]
        let product = enter(.fleet, "collect", keys: order)
        guard let next = product.nextLevel(order, among: product.filter(all)) else {
            return XCTFail("env is carried, so a level should have been offered")
        }
        XCTAssertEqual(next.key, "env")
        XCTAssertEqual(next.level, 2, "it is the third key, not the second")
        let env = product.entering(level: next.level, key: next.key, value: "prod")
        XCTAssertEqual(env.filter(all).map(\.id), ["i-0"])
        XCTAssertNil(env.nextLevel(order, among: env.filter(all)),
                     "the skipped key is behind us, not still to come")
    }

    func testAnUntaggedGroupIsNamedRatherThanBlank() {
        let focus = ClusterFocus.fleet.entering(level: 0, key: "product", value: "")
        XCTAssertEqual(focus.label, "untagged")
    }
}
