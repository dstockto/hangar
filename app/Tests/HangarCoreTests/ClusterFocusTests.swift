import XCTest
@testable import HangarCore

/// Drilling asks one question at each level: which hosts am I now looking at.
final class ClusterFocusTests: XCTestCase {
    private let keys = ["product", "env"]

    private func host(_ product: String, _ env: String, _ name: String = "web",
                      id: String = "i-0000000000000000a", team: String = "core") -> Instance {
        Fixture.instance(["product": product, "env": env, "Name": name, "Team": team], id: id)
    }

    func testTheFleetShowsEverything() {
        let all = [host("payments", "prod"), host("billing", "dev")]
        XCTAssertEqual(ClusterFocus.fleet.filter(all, groupingKeys: keys).count, 2)
        XCTAssertEqual(ClusterFocus.fleet.label, "")
        XCTAssertTrue(ClusterFocus.fleet.isFleet)
    }

    func testEnteringTheFirstLevelKeepsEveryEnvironmentUnderIt() {
        let all = [host("payments", "prod"), host("payments", "stage"),
                   host("billing", "prod")]
        let focus = ClusterFocus.fleet.entering("payments")
        XCTAssertEqual(focus.filter(all, groupingKeys: keys).count, 2)
        XCTAssertEqual(focus.label, "payments")
    }

    func testEnteringTheSecondLevelNarrowsToOneGroup() {
        let all = [host("payments", "prod"), host("payments", "stage"),
                   host("billing", "prod")]
        let focus = ClusterFocus.fleet.entering("payments").entering("prod")
        XCTAssertEqual(focus.filter(all, groupingKeys: keys).count, 1)
        XCTAssertEqual(focus.label, "payments · prod")
    }

    func testOpeningAHostNarrowsToThatOneInstance() {
        let all = [host("payments", "prod", "web", id: "i-0000000000000000a"),
                   host("payments", "prod", "web", id: "i-0000000000000000b")]
        let focus = ClusterFocus.fleet.entering("payments").entering("prod")
            .opening(host: "i-0000000000000000b")
        XCTAssertEqual(focus.filter(all, groupingKeys: keys).map(\.id),
                       ["i-0000000000000000b"])
    }

    func testLeavingUndoesOneLevelAtATime() {
        let host = ClusterFocus.fleet.entering("payments").entering("prod")
            .opening(host: "i-0")
        let group = host.leaving()
        XCTAssertNil(group.hostID)
        XCTAssertEqual(group.label, "payments · prod")
        XCTAssertEqual(group.leaving().label, "payments")
        XCTAssertTrue(group.leaving().leaving().isFleet)
        XCTAssertTrue(ClusterFocus.fleet.leaving().isFleet, "the fleet is the floor")
    }

    func testBackNamesWhereItGoesAtEveryDepth() {
        XCTAssertNil(ClusterFocus.fleet.backDestination,
                     "the fleet has nowhere further out, so nothing offers a way there")
        let product = ClusterFocus.fleet.entering("payments")
        XCTAssertEqual(product.backDestination, "", "back from a product is the fleet")
        let env = product.entering("prod")
        XCTAssertEqual(env.backDestination, "payments")
        XCTAssertEqual(env.opening(host: "i-0").backDestination, "payments · prod",
                       "an open host steps back to the group it was in")
    }

    func testTheNextLevelComesFromTheConfiguredKeys() {
        XCTAssertEqual(ClusterFocus.fleet.nextKey(keys), "product")
        XCTAssertEqual(ClusterFocus.fleet.entering("payments").nextKey(keys), "env")
        XCTAssertNil(ClusterFocus.fleet.entering("payments").entering("prod").nextKey(keys),
                     "below the last level are hosts, not another group")
    }

    func testItFollowsTheConfiguredGroupingRatherThanTheDefaults() {
        let all = [host("payments", "prod", team: "core"),
                   host("billing", "prod", team: "core"),
                   host("edge", "prod", team: "edge")]
        let focus = ClusterFocus.fleet.entering("core")
        XCTAssertEqual(focus.filter(all, groupingKeys: ["Team"]).count, 2)
    }
}
