import XCTest
@testable import HangarCore

final class AliasTests: XCTestCase {

    func testEnvAndRole() {
        XCTAssertEqual(Fixture.instance(["env": "prod", "Name": "xfer"]).aliasStem,
                       "prod-xfer")
    }

    func testProductLeadsTheStemWhenTagged() {
        XCTAssertEqual(
            Fixture.instance(["product": "payments", "env": "prod", "Name": "web"]).aliasStem,
            "payments-prod-web")
    }

    func testDifferentProductsNeverShareAStem() {
        // Without the product in the stem, every product's prod web box lands in
        // one group and gets numbered against the others.
        XCTAssertNotEqual(
            Fixture.instance(["product": "payments", "env": "prod", "Name": "web"]).aliasStem,
            Fixture.instance(["product": "media", "env": "prod", "Name": "web"]).aliasStem)
    }

    func testLeafLabelDropsTheGroupingItSitsUnder() {
        XCTAssertEqual(
            Fixture.instance(["product": "payments", "env": "prod", "Name": "web"])
                .leafLabel(alias: "payments-prod-web-1", groupedBy: ["product", "env"]),
            "web-1")
    }

    func testLeafLabelKeepsWhatTheMenuDidNotGroupBy() {
        // Grouped by product alone, the env has to stay in the label. It used to
        // be cut regardless, so a product with prod, stage and qa web boxes
        // listed "web-1" three times with nothing to tell them apart.
        let instance = Fixture.instance(["product": "payments", "env": "prod", "Name": "web"])
        XCTAssertEqual(instance.leafLabel(alias: "payments-prod-web-1",
                                          groupedBy: ["product"]),
                       "prod-web-1")
    }

    /// The case a real fleet hit: env_name exists only on the replication
    /// instances, so it is a poor grouping level and a good part of a name.
    /// Grouped by product and env alone, it has to survive into the label, or a
    /// replica and its primary are two circles both called "archive".
    func testAnOptionalTagSurvivesIntoTheLabelWhenItIsNotALevel() {
        let primary = Fixture.instance(["product": "screen", "env": "prod",
                                        "Name": "archive"])
        let replica = Fixture.instance(["product": "screen", "env": "prod",
                                        "env_name": "repl", "Name": "archive"])
        let levels = ["product", "env"]
        XCTAssertEqual(primary.leafLabel(alias: primary.aliasStem, groupedBy: levels),
                       "archive")
        XCTAssertEqual(replica.leafLabel(alias: replica.aliasStem, groupedBy: levels),
                       "repl-archive")
        XCTAssertNotEqual(primary.leafLabel(alias: primary.aliasStem, groupedBy: levels),
                          replica.leafLabel(alias: replica.aliasStem, groupedBy: levels))
    }

    func testLeafLabelIsUntouchedWhenNothingIsGroupedBy() {
        let instance = Fixture.instance(["product": "payments", "env": "prod", "Name": "web"])
        XCTAssertEqual(instance.leafLabel(alias: "payments-prod-web-1", groupedBy: []),
                       "payments-prod-web-1")
    }

    func testLeafLabelIgnoresLevelsThatAreNotInTheAlias() {
        // A fleet grouped by a tag the alias does not carry keeps the whole alias,
        // rather than having an unrelated prefix chopped off it.
        let instance = Fixture.instance(["product": "payments", "env": "prod",
                                         "Name": "web", "Team": "core"])
        XCTAssertEqual(instance.leafLabel(alias: "payments-prod-web-1",
                                          groupedBy: ["Team"]),
                       "payments-prod-web-1")
    }

    func testEnvNameIsIncluded() {
        XCTAssertEqual(
            Fixture.instance(["env": "sb", "env_name": "zg1873c", "Name": "web"]).aliasStem,
            "sb-zg1873c-web")
    }

    func testSlugifiesAwkwardValues() {
        XCTAssertEqual(Fixture.instance(["env": "Pre Prod", "Name": "web_1"]).aliasStem,
                       "pre-prod-web-1")
    }

    func testFallsBackToTheInstanceIdWhenUntagged() {
        XCTAssertEqual(Fixture.instance([:], id: "i-abc").aliasStem, "i-abc")
    }

    func testHostnameTagWinsOverPrivateIP() {
        XCTAssertEqual(Fixture.instance(["hostname": "a.web.prod.example.com"]).host,
                       "a.web.prod.example.com")
        XCTAssertEqual(Fixture.instance([:]).host, "10.0.0.1")
    }

    func testDetectsASGMembership() {
        XCTAssertTrue(Fixture.instance(["aws:autoscaling:groupName": "payments-xfer-prod"]).isASG)
    }

    func testFriendlyTagNamesResolve() {
        let instance = Fixture.instance(["env": "qa", "Name": "web"])
        XCTAssertEqual(instance.tagValue(for: "name"), "web")
        XCTAssertEqual(instance.tagValue(for: "env"), "qa")
    }
}

final class WildcardTests: XCTestCase {

    func testExactMatch() {
        XCTAssertTrue(HangarConfig.wildcard("prod", "prod"))
        XCTAssertFalse(HangarConfig.wildcard("prod", "production"))
    }

    func testWildcards() {
        XCTAssertTrue(HangarConfig.wildcard("pg2*", "pg2-dev"))
        XCTAssertTrue(HangarConfig.wildcard("*prod", "hfprod"))
        XCTAssertTrue(HangarConfig.wildcard("*", "whatever"))
    }
}

final class LoginCandidateTests: XCTestCase {

    func testTheEffectiveLoginIsTriedFirst() {
        XCTAssertEqual(SSHLogin.candidates(effective: "deploy-user").first, "deploy-user")
    }

    func testTheUsualCloudImagesAreCovered() {
        let candidates = SSHLogin.candidates(effective: nil)
        for login in ["ec2-user", "rocky", "ubuntu", "centos", "debian"] {
            XCTAssertTrue(candidates.contains(login), "missing \(login)")
        }
    }

    func testNoDuplicates() {
        let candidates = SSHLogin.candidates(effective: "ec2-user")
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }
}
