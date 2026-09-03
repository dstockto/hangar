import XCTest
@testable import HangarCore

final class OverrideTests: XCTestCase {

    private let hostMatch = ["id": "i-0aaaaaaaaaaaaaaaa"]
    private let productMatch = ["product": "payments"]

    private var target: Instance {
        Fixture.instance(["product": "payments", "env": "prod", "Name": "web",
                          "hostname": "web.prod.payments.example.com"],
                         id: "i-0aaaaaaaaaaaaaaaa")
    }
    private var other: Instance {
        Fixture.instance(["product": "payments", "env": "qa", "Name": "web",
                          "hostname": "web.qa.payments.example.com"],
                         id: "i-0bbbbbbbbbbbbbbbb")
    }

    func testAnOverrideRoundTrips() {
        var config = HangarConfig.standard()
        config.setOverride(match: hostMatch, user: "rocky", identityFile: nil)
        XCTAssertEqual(config.overrides?.count, 1)
        XCTAssertEqual(config.override(for: hostMatch)?.user, "rocky")
    }

    func testResavingTheSameScopeReplacesRatherThanDuplicates() {
        var config = HangarConfig.standard()
        config.setOverride(match: hostMatch, user: "rocky", identityFile: nil)
        config.setOverride(match: hostMatch, user: "ec2-user", identityFile: "~/k.pem")
        XCTAssertEqual(config.overrides?.count, 1)
        XCTAssertEqual(config.override(for: hostMatch)?.user, "ec2-user")
        XCTAssertEqual(config.override(for: hostMatch)?.identityFile, "~/k.pem")
    }

    func testGeneralRulesAreOrderedBeforeSpecificOnes() {
        // Overrides merge top to bottom, so the broad rule has to come first for
        // the host-specific one to win.
        var config = HangarConfig.standard()
        config.setOverride(match: hostMatch, user: "ec2-user", identityFile: "~/k.pem")
        config.setOverride(match: productMatch, user: "rocky", identityFile: nil)
        let order = config.overrides!.map { $0.match.keys.sorted().joined(separator: "+") }
        XCTAssertEqual(order.first, "product")
        XCTAssertEqual(order.last, "id")
    }

    func testTheHostSpecificRuleWins() {
        var config = HangarConfig.standard()
        config.setOverride(match: hostMatch, user: "ec2-user", identityFile: "~/k.pem")
        config.setOverride(match: productMatch, user: "rocky", identityFile: nil)
        let resolved = config.sshSettings(for: target)
        XCTAssertEqual(resolved.user, "ec2-user")
        XCTAssertEqual(resolved.identityFile, "~/k.pem")

        let sibling = config.sshSettings(for: other)
        XCTAssertEqual(sibling.user, "rocky")
        XCTAssertNil(sibling.identityFile, "the host rule must not reach its sibling")
    }

    func testScopesMergeInsteadOfOverwritingWholesale() {
        var config = HangarConfig.standard()
        config.setOverride(match: productMatch, user: "rocky", identityFile: nil)
        config.setOverride(match: hostMatch, user: nil, identityFile: "~/special.pem")
        let merged = config.sshSettings(for: target)
        XCTAssertEqual(merged.user, "rocky")
        XCTAssertEqual(merged.identityFile, "~/special.pem")

        let rendered = SSHConfigWriter(config: config)
            .render(instances: [target, other], region: "us-west-2")
        XCTAssertTrue(rendered.contains("IdentityFile ~/special.pem"))
        XCTAssertTrue(rendered.contains("User rocky"))
        XCTAssertTrue(rendered.contains("IdentitiesOnly yes"))
    }

    func testClearingBothFieldsRemovesTheOverride() {
        var config = HangarConfig.standard()
        config.setOverride(match: hostMatch, user: "rocky", identityFile: nil)
        config.setOverride(match: productMatch, user: "rocky", identityFile: nil)
        config.setOverride(match: hostMatch, user: nil, identityFile: nil)
        XCTAssertNil(config.override(for: hostMatch))
        XCTAssertNotNil(config.override(for: productMatch), "the other scope is untouched")
    }
}

final class ConfigCodingTests: XCTestCase {

    func testDefaults() {
        let standard = HangarConfig.standard()
        XCTAssertEqual(standard.healthyWithinHours, 24)
        XCTAssertEqual(standard.updateChannel, "stable")
        XCTAssertEqual(standard.checkUpdatesOnLaunch, true,
                       "the update check is on by default")
        XCTAssertEqual(standard.updateCheckHours, 24, "and runs at most once a day")
        XCTAssertEqual(standard.tags, .standard,
                       "a fresh config ships the tag mapping so it can be edited")
    }

    func testRoundTripUsesSnakeCaseKeys() throws {
        let encoded = try JSONEncoder().encode(HangarConfig.standard())
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("healthy_within_hours"), text)
        let decoded = try JSONDecoder().decode(HangarConfig.self, from: encoded)
        XCTAssertEqual(decoded.healthyWithinHours, 24)
    }

    func testACustomWindowIsPreserved() throws {
        var custom = HangarConfig.standard()
        custom.healthyWithinHours = 6
        let encoded = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(HangarConfig.self, from: encoded)
            .healthyWithinHours, 6)
    }

    func testAConfigWrittenBeforeAKeyExistedStillLoads() throws {
        let older = Data("{\"refresh_minutes\":30}".utf8)
        let decoded = try JSONDecoder().decode(HangarConfig.self, from: older)
        XCTAssertNil(decoded.healthyWithinHours)
        XCTAssertEqual(decoded.refreshMinutes, 30)
    }
}

final class VersionCompareTests: XCTestCase {

    func testNumericNotLexical() {
        XCTAssertTrue(VersionCompare.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(VersionCompare.isNewer("0.9.0", than: "0.10.0"))
    }

    /// The boundary this project actually crossed: leaving the 0.0.x line for
    /// 0.1.0 while a 0.0.10 existed. Sorted as text, "0.1.0" is the smaller
    /// string, and everyone on 0.0.10 would have been stranded there.
    func testAMinorBumpOutranksATwoDigitPatch() {
        XCTAssertTrue(VersionCompare.isNewer("0.1.0", than: "0.0.10"))
        XCTAssertFalse(VersionCompare.isNewer("0.0.10", than: "0.1.0"))
        XCTAssertTrue(VersionCompare.isNewer("0.0.10", than: "0.0.9"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(VersionCompare.isNewer("1.2.3", than: "1.2.3"))
    }

    func testPrefixAndMissingComponents() {
        XCTAssertTrue(VersionCompare.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertTrue(VersionCompare.isNewer("1.1", than: "1.0.9"))
    }

    func testPrereleaseOrdering() {
        XCTAssertTrue(VersionCompare.isNewer("0.4.0", than: "0.4.0-beta.1"))
        XCTAssertFalse(VersionCompare.isNewer("0.4.0-beta.1", than: "0.4.0"))
        XCTAssertTrue(VersionCompare.isNewer("0.4.0-beta.10", than: "0.4.0-beta.2"))
    }

    func testAStableHotfixDoesNotOutrankANewerBeta() {
        XCTAssertFalse(VersionCompare.isNewer("0.4.1", than: "0.5.0-beta.1"))
        XCTAssertTrue(VersionCompare.isNewer("0.5.0-beta.1", than: "0.4.1"))
    }
}
