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
                .leafLabel(alias: "payments-prod-web-1"),
            "web-1")
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
