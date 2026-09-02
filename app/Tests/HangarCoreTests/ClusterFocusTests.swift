import XCTest
@testable import HangarCore

/// Drilling into a circle asks one question: which hosts am I now looking at.
final class ClusterFocusTests: XCTestCase {
    private let keys = ["product", "env"]

    private func host(_ product: String, _ env: String, team: String = "core") -> Instance {
        Fixture.instance(["product": product, "env": env, "Name": "web", "Team": team])
    }

    func testTheFleetShowsEverything() {
        let all = [host("payments", "prod"), host("billing", "dev")]
        XCTAssertEqual(ClusterFocus.fleet.filter(all, groupingKeys: keys).count, 2)
        XCTAssertEqual(ClusterFocus.fleet.label, "")
    }

    func testAGroupShowsOnlyItsOwnHosts() {
        let all = [host("payments", "prod"), host("payments", "stage"),
                   host("billing", "prod")]
        let focus = ClusterFocus.group(product: "payments", env: "prod")
        XCTAssertEqual(focus.filter(all, groupingKeys: keys).count, 1)
        XCTAssertEqual(focus.label, "payments · prod")
    }

    func testAProductWithNoEnvLevelKeepsEveryEnvironment() {
        let all = [host("payments", "prod"), host("payments", "stage"),
                   host("billing", "prod")]
        let focus = ClusterFocus.group(product: "payments", env: nil)
        XCTAssertEqual(focus.filter(all, groupingKeys: ["product"]).count, 2)
        XCTAssertEqual(focus.label, "payments")
    }

    func testItFollowsTheConfiguredGroupingRatherThanTheDefaults() {
        // A fleet grouped by Team drills on Team, not on the product tag.
        let all = [host("payments", "prod", team: "core"),
                   host("billing", "prod", team: "core"),
                   host("edge", "prod", team: "edge")]
        let focus = ClusterFocus.group(product: "core", env: nil)
        XCTAssertEqual(focus.filter(all, groupingKeys: ["Team"]).count, 2)
    }
}
