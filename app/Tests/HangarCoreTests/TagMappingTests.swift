import XCTest
@testable import HangarCore

/// Whether Hangar is usable by a fleet that never heard of its tag conventions.
final class TagMappingTests: XCTestCase {

    private let mapping = TagMapping.standard

    // MARK: - Fleets that are not ours

    func testCommonConventionsWorkWithNoConfiguration() {
        // Environment/Service/Component, the most common shape in the wild.
        let instance = mapping.normalize(Fixture.instance([
            "Service": "payments", "Environment": "prod", "Component": "web"]))
        XCTAssertEqual(instance.product, "payments")
        XCTAssertEqual(instance.env, "prod")
        XCTAssertEqual(instance.role, "web")
        XCTAssertEqual(instance.aliasStem, "payments-prod-web")
    }

    func testCaseDoesNotMatter() {
        let instance = mapping.normalize(Fixture.instance([
            "SERVICE": "billing", "ENV": "qa", "NAME": "db"]))
        XCTAssertEqual(instance.aliasStem, "billing-qa-db")
    }

    func testAppAndStageAlsoResolve() {
        let instance = mapping.normalize(Fixture.instance([
            "app": "search", "stage": "uat", "role": "worker"]))
        XCTAssertEqual(instance.aliasStem, "search-uat-worker")
    }

    func testNameOnlyIsEnoughForAUsableAlias() {
        // The single most common case: one Name tag and nothing else.
        let instance = mapping.normalize(Fixture.instance(["Name": "bastion-prod-1"]))
        XCTAssertEqual(instance.aliasStem, "bastion-prod-1")
        XCTAssertFalse(TagMapping.isUngrouped(instance))
    }

    func testAnEntirelyUntaggedInstanceStillGetsAWorkingAlias() {
        let instance = mapping.normalize(Fixture.instance([:], id: "i-0abc123def456789"))
        XCTAssertEqual(instance.aliasStem, "i-0abc123def456789")
        XCTAssertTrue(TagMapping.isUngrouped(instance))
    }

    func testUntaggedInstancesDoNotGetAnAliasPinnedToThemselves() {
        // Regression: the id-based alias used to be appended unconditionally,
        // producing "i-0abc123def-i-0abc123de" beside the id.
        let instance = mapping.normalize(Fixture.instance([:], id: "i-0abc123def456789"))
        let entries = SSHConfigWriter(config: .standard()).entries(for: [instance])
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].aliases.contains { $0.contains("-i-0") },
                       "got \(entries[0].aliases)")
    }

    func testAFleetUsingItsOwnKeysCanSaySo() {
        var custom = TagMapping.standard
        custom.product = ["BusinessUnit"]
        custom.env = ["DeployTier"]
        let instance = custom.normalize(Fixture.instance([
            "BusinessUnit": "risk", "DeployTier": "staging", "Name": "api"]))
        XCTAssertEqual(instance.aliasStem, "risk-staging-api")
    }

    // MARK: - Mechanics

    func testOriginalTagsSurviveSoFiltersAndOverridesStillWork() {
        let instance = mapping.normalize(Fixture.instance([
            "Service": "payments", "Team": "platform"]))
        XCTAssertEqual(instance.tags["Service"], "payments", "the original key is kept")
        XCTAssertEqual(instance.tags["product"], "payments", "and the canonical one added")
        XCTAssertEqual(instance.tagValue(for: "Team"), "platform",
                       "an unmapped tag is still filterable")
    }

    func testCandidateOrderDecidesTheWinner() {
        // "product" comes before "Service" in the defaults, so it wins.
        let instance = mapping.normalize(Fixture.instance([
            "product": "explicit", "Service": "fallback"]))
        XCTAssertEqual(instance.product, "explicit")
    }

    func testEmptyValuesAreNotTreatedAsPresent() {
        let instance = mapping.normalize(Fixture.instance(["env": "", "Environment": "prod"]))
        XCTAssertEqual(instance.env, "prod")
    }

    func testACanonicalKeyDoesNotLingerWhenTheMappingChanges() {
        // A cached instance normalized under an old mapping, re-normalized under
        // one that no longer resolves that idea, must not keep the stale value.
        var narrow = TagMapping.standard
        narrow.product = ["NothingMatchesThis"]
        let once = TagMapping.standard.normalize(
            Fixture.instance(["Service": "payments", "Name": "web"]))
        XCTAssertEqual(once.product, "payments")
        let again = narrow.normalize(once)
        XCTAssertEqual(again.product, "", "stale canonical value must be cleared")
        XCTAssertEqual(again.role, "web")
    }

    func testHostnameCandidatesResolve() {
        let instance = mapping.normalize(Fixture.instance([
            "FQDN": "web1.prod.example.com", "Name": "web"]))
        XCTAssertEqual(instance.host, "web1.prod.example.com")
    }

    func testPrivateIPRemainsTheFallbackHost() {
        let instance = mapping.normalize(Fixture.instance(["Name": "web"]))
        XCTAssertEqual(instance.host, "10.0.0.1")
    }

    func testMappingRoundTripsThroughConfig() throws {
        var config = HangarConfig.standard()
        config.tags?.product = ["BusinessUnit"]
        let encoded = try JSONEncoder().encode(config)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)?.contains("env_name") == true)
        let decoded = try JSONDecoder().decode(HangarConfig.self, from: encoded)
        XCTAssertEqual(decoded.tagMapping.product, ["BusinessUnit"])
    }

    func testAConfigWithNoTagsSectionFallsBackToTheDefaults() throws {
        let older = Data("{\"refresh_minutes\":30}".utf8)
        let decoded = try JSONDecoder().decode(HangarConfig.self, from: older)
        XCTAssertNil(decoded.tags)
        XCTAssertEqual(decoded.tagMapping, .standard)
    }
}

final class UpdateScheduleTests: TemporaryDirectoryTestCase {

    func testDailyByDefault() {
        XCTAssertEqual(HangarConfig.standard().updateCheckHours, 24)
        XCTAssertEqual(HangarConfig.standard().checkUpdatesOnLaunch, true)
    }

    func testZeroOrNegativeHoursTurnsItOff() {
        XCTAssertFalse(UpdateSchedule.isDue(every: 0, lastCheck: nil))
        XCTAssertFalse(UpdateSchedule.isDue(every: -1, lastCheck: nil))
    }

    func testDueWhenItHasNeverRun() {
        XCTAssertTrue(UpdateSchedule.isDue(every: 24, lastCheck: nil))
    }

    func testNotDueAgainWithinTheWindow() {
        let now = Date()
        XCTAssertFalse(UpdateSchedule.isDue(
            every: 24, now: now, lastCheck: now.addingTimeInterval(-3600)))
        XCTAssertTrue(UpdateSchedule.isDue(
            every: 24, now: now, lastCheck: now.addingTimeInterval(-25 * 3600)))
    }

    func testTheStampSurvivesARestart() throws {
        let stamp = path("last-update-check")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        UpdateSchedule.recordCheck(at: when, path: stamp)
        let recovered = try XCTUnwrap(UpdateSchedule.lastCheck(path: stamp))
        XCTAssertEqual(recovered.timeIntervalSince1970, when.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertFalse(UpdateSchedule.isDue(every: 24, now: when.addingTimeInterval(60),
                                            path: stamp))
    }

    func testAMissingStampIsNotAnError() {
        XCTAssertNil(UpdateSchedule.lastCheck(path: path("never-written")))
    }
}
