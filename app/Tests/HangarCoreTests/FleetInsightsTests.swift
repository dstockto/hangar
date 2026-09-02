import XCTest
@testable import HangarCore

/// The dashboard's numbers, computed from the one DescribeInstances response
/// Hangar already holds. Nothing here may need another call: that is the whole
/// constraint the feature was designed inside.
final class FleetInsightsTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-09-02T12:00:00Z")!

    private func host(_ product: String, _ env: String, _ name: String,
                      id: String = "i-0000000000000000a",
                      zone: String = "us-west-2a",
                      state: String = "running",
                      type: String = "m6i.large",
                      launched: String = "2026-09-01T12:00:00Z",
                      hostname: String? = "h.example.com",
                      publicIP: String? = nil,
                      asg: String? = nil) -> Instance {
        var tags = ["product": product, "env": env, "Name": name]
        if let hostname { tags["hostname"] = hostname }
        if let asg { tags["aws:autoscaling:groupName"] = asg }
        return Instance(id: id, state: state, type: type, privateIP: "10.0.0.1",
                        publicIP: publicIP, availabilityZone: zone,
                        launchTime: launched, tags: tags)
    }

    // MARK: - Hygiene

    func testHygieneCountsTheHostsHangarServesBadly() {
        let insights = FleetInsights.compute([
            host("payments", "prod", "web-1"),
            host("", "prod", "web-2"),
            host("payments", "", "web-3"),
            host("payments", "prod", ""),
            host("payments", "prod", "web-4", hostname: nil),
        ], now: now)
        XCTAssertEqual(insights.hygiene.missingProduct, 1)
        XCTAssertEqual(insights.hygiene.missingEnv, 1)
        XCTAssertEqual(insights.hygiene.missingName, 1)
        XCTAssertEqual(insights.hygiene.missingHostname, 1)
        XCTAssertFalse(insights.hygiene.isClean)
        XCTAssertEqual(insights.hygiene.problems, 4)
    }

    func testSharedNamesAreReportedWithoutBeingCalledDirty() {
        // Two hosts whose tags produce one stem. SSHConfigWriter numbers them,
        // so this is information, not a fault, and it must not make an
        // otherwise well-tagged fleet report as unclean.
        let insights = FleetInsights.compute([
            host("payments", "prod", "web", id: "i-0000000000000000a"),
            host("payments", "prod", "web", id: "i-0000000000000000b"),
            host("payments", "prod", "db"),
        ], now: now)
        XCTAssertEqual(insights.hygiene.sharedNames, ["payments-prod-web": 2])
        XCTAssertTrue(insights.hygiene.isClean, "shared names are handled, not dirt")
        XCTAssertEqual(insights.hygiene.problems, 0)
    }

    func testACleanFleetSaysSo() {
        let insights = FleetInsights.compute([
            host("payments", "prod", "web-1"), host("payments", "prod", "web-2"),
        ], now: now)
        XCTAssertTrue(insights.hygiene.isClean)
        XCTAssertTrue(insights.hygiene.sharedNames.isEmpty)
    }

    // MARK: - Placement

    func testASingleZoneGroupIsFlaggedButASingleHostIsNot() {
        let insights = FleetInsights.compute([
            host("payments", "prod", "web-1", zone: "us-west-2a"),
            host("payments", "prod", "web-2", zone: "us-west-2a"),
            host("billing", "prod", "api-1", zone: "us-west-2b"),
            host("edge", "prod", "cache-1", zone: "us-west-2a"),
            host("edge", "prod", "cache-2", zone: "us-west-2c"),
        ], now: now)
        let payments = insights.placement.first { $0.product == "payments" }
        let billing = insights.placement.first { $0.product == "billing" }
        let edge = insights.placement.first { $0.product == "edge" }
        XCTAssertEqual(payments?.isSingleZone, true)
        XCTAssertEqual(billing?.isSingleZone, false, "one host cannot be spread")
        XCTAssertEqual(edge?.isSingleZone, false)
        XCTAssertEqual(edge?.zones, ["us-west-2a", "us-west-2c"])
    }

    func testAutoscalingCoverageSeparatesCattleFromPets() {
        let insights = FleetInsights.compute([
            host("payments", "prod", "web-1", asg: "payments-prod-web"),
            host("payments", "prod", "web-2", asg: "payments-prod-web"),
            host("payments", "prod", "db-1"),
        ], now: now)
        let group = insights.placement.first { $0.product == "payments" }
        XCTAssertEqual(group?.inAutoscalingGroup, 2)
        XCTAssertEqual(group?.pets, 1)
    }

    func testUntaggedHostsGroupUnderAName() {
        let insights = FleetInsights.compute([host("", "", "orphan")], now: now)
        XCTAssertEqual(insights.placement.first?.product, "untagged")
        XCTAssertEqual(insights.placement.first?.env, "untagged")
    }

    // MARK: - Age

    func testAgeBucketBoundaries() {
        let cases: [(String, String)] = [
            ("2026-09-02T06:00:00Z", "under a day"),
            ("2026-08-30T12:00:00Z", "under a week"),
            ("2026-08-20T12:00:00Z", "under a month"),
            ("2026-07-15T12:00:00Z", "under 90 days"),
            ("2026-05-01T12:00:00Z", "under 180 days"),
            ("2025-01-01T12:00:00Z", "over 180 days"),
        ]
        for (launched, expected) in cases {
            let insights = FleetInsights.compute(
                [host("p", "e", "n", launched: launched)], now: now)
            let filled = insights.ages.filter { $0.count > 0 }
            XCTAssertEqual(filled.map(\.label), [expected], "launched \(launched)")
        }
    }

    func testAnUnreadableLaunchTimeIsReportedRatherThanCountedAsNew() {
        let insights = FleetInsights.compute(
            [host("p", "e", "n", launched: "not a date")], now: now)
        XCTAssertEqual(insights.ages.last?.label, "launch time unreadable")
        XCTAssertEqual(insights.ages.last?.count, 1)
        XCTAssertEqual(insights.ages.first { $0.label == "under a day" }?.count, 0)
    }

    // MARK: - Families and exposure

    func testFamiliesAreCountedAndFlagged() {
        let insights = FleetInsights.compute([
            host("p", "e", "1", type: "m6i.large"),
            host("p", "e", "2", type: "m6i.xlarge"),
            host("p", "e", "3", type: "t2.micro"),
            host("p", "e", "4", type: "m7g.large"),
        ], now: now)
        XCTAssertEqual(insights.families.first?.family, "m6i")
        XCTAssertEqual(insights.families.first?.count, 2)
        let t2 = insights.families.first { $0.family == "t2" }
        XCTAssertEqual(t2?.isBurstable, true)
        XCTAssertEqual(t2?.isPreviousGeneration, true)
        let m7g = insights.families.first { $0.family == "m7g" }
        XCTAssertEqual(m7g?.isPreviousGeneration, false)
        XCTAssertEqual(insights.families.first { $0.family == "m6i" }?.isPreviousGeneration,
                       false, "one behind the newest is not a finding")
    }

    func testExposureIsCountedPerEnvironment() {
        let insights = FleetInsights.compute([
            host("p", "prod", "1", publicIP: "203.0.113.10"),
            host("p", "prod", "2"),
            host("p", "dev", "3", publicIP: "203.0.113.11"),
        ], now: now)
        let prod = insights.exposure.first { $0.env == "prod" }
        XCTAssertEqual(prod?.withPublicAddress, 1)
        XCTAssertEqual(prod?.total, 2)
        XCTAssertEqual(insights.exposure.first { $0.env == "dev" }?.withPublicAddress, 1)
    }

    func testStateTotals() {
        let insights = FleetInsights.compute([
            host("p", "e", "1"), host("p", "e", "2", state: "stopped"),
            host("p", "e", "3", state: "pending"),
        ], now: now)
        XCTAssertEqual(insights.total, 3)
        XCTAssertEqual(insights.running, 1)
        XCTAssertEqual(insights.stopped, 1)
    }

    func testAnEmptyFleetComputesRatherThanCrashing() {
        let insights = FleetInsights.compute([], now: now)
        XCTAssertEqual(insights.total, 0)
        XCTAssertTrue(insights.placement.isEmpty)
        XCTAssertTrue(insights.hygiene.isClean)
    }
}
