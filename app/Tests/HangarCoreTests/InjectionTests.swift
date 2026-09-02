import XCTest
@testable import HangarCore

/// Regressions for two ways an EC2 tag reached `ssh` with more authority than a
/// hostname should have. Both were found by a security review of the published
/// tree, and both were reproduced against the real `ssh` before being fixed.
final class InjectionTests: TemporaryDirectoryTestCase {

    // MARK: - A tag parsed by ssh as an option

    func testAHostnameTagCannotBecomeAnSSHOption() {
        // `ssh … -oProxyCommand=<command> true` runs the command: because a
        // trailing argument follows, ssh parses the leading "-o" as an option and
        // "true" as the host. An argument vector does not help; only "--" does.
        let arguments = SSHProbe.arguments(
            host: "-oProxyCommand=touch /tmp/pwned", user: "ec2-user", identityFile: nil)
        guard let separator = arguments.firstIndex(of: "--") else {
            return XCTFail("no -- in \(arguments)")
        }
        guard let host = arguments.firstIndex(of: "-oProxyCommand=touch /tmp/pwned") else {
            return XCTFail("host missing from \(arguments)")
        }
        XCTAssertLessThan(separator, host, "-- must precede the host")
        XCTAssertEqual(arguments.last, "true", "the remote command still comes last")
    }

    func testTheProbeStillWorksForAnOrdinaryHost() {
        let arguments = SSHProbe.arguments(
            host: "web-1.prod.example.com", user: "deploy", identityFile: "~/k.pem")
        XCTAssertEqual(arguments.suffix(3), ["--", "web-1.prod.example.com", "true"])
        XCTAssertTrue(arguments.contains("BatchMode=yes"), "never prompt")
        XCTAssertTrue(arguments.contains("IdentitiesOnly=yes"), "a pinned key is pinned")
    }

    // MARK: - A tag acting as a Host pattern

    func testAWildcardTagCannotBecomeACatchAllHostPattern() throws {
        // `Host *` is a catch-all. Hangar's Include sits at the top of the user's
        // ~/.ssh/config and ssh_config is first-match-wins, so one tag of "*"
        // took over every host they had, silently: ssh accepts the file.
        let hostile = Fixture.instance(
            ["product": "payments", "env": "prod", "Name": "web", "hostname": "*"],
            id: "i-0hostile")
        let ordinary = Fixture.instance(
            ["product": "shop", "env": "prod", "Name": "db",
             "hostname": "db-1.prod.example.com"], id: "i-0ordinary")

        let target = path("hangar")
        let writer = SSHConfigWriter(config: .standard())
        _ = try writer.sync(instances: [hostile, ordinary], region: "us-west-2", to: target)
        let text = try String(contentsOfFile: target, encoding: .utf8)

        for line in text.components(separatedBy: .newlines) where line.hasPrefix("Host ") {
            XCTAssertFalse(line.contains("*"), "a Host pattern must never be a wildcard: \(line)")
            XCTAssertFalse(line.contains("?"), "nor a single-character wildcard: \(line)")
        }
        XCTAssertNil(SSHConfigWriter.validate(target))

        // The ordinary host is untouched by its neighbour's bad tag.
        XCTAssertTrue(text.contains("db-1.prod.example.com"), text)
    }

    func testAWildcardDNSRecordIsRefusedAsAnAliasButStillReachable() throws {
        // The accidental version: a legitimate wildcard DNS record in a tag.
        // It cannot be an alias, but the host must still get its own entry.
        let instance = Fixture.instance(
            ["product": "shop", "env": "staging", "Name": "web",
             "hostname": "*.staging.example.com"], id: "i-0wild")
        let target = path("hangar")
        let result = try SSHConfigWriter(config: .standard())
            .sync(instances: [instance], region: "us-west-2", to: target)
        let text = try String(contentsOfFile: target, encoding: .utf8)

        XCTAssertEqual(result.hostCount, 1, "the host is still written")
        XCTAssertTrue(text.contains("Host shop-staging-web"), text)
        XCTAssertFalse(text.contains("Host shop-staging-web *"), text)
        XCTAssertNil(SSHConfigWriter.validate(target))
    }

    func testALeadingHyphenIsRefusedAsAnAlias() {
        XCTAssertFalse(SSHConfigValue.isSafeAlias("-oProxyCommand=x"))
        XCTAssertFalse(SSHConfigValue.isSafeAlias("-l"))
    }

    func testSafeAliasAcceptsWhatARealHostLooksLike() {
        XCTAssertTrue(SSHConfigValue.isSafeAlias("web-1.prod.example.com"))
        XCTAssertTrue(SSHConfigValue.isSafeAlias("payments-prod-web-1"))
        XCTAssertTrue(SSHConfigValue.isSafeAlias("i-0abc123def456789"))
        XCTAssertTrue(SSHConfigValue.isSafeAlias("10.0.0.1"))
        XCTAssertTrue(SSHConfigValue.isSafeAlias("host_1"))
    }

    func testSafeAliasRefusesPatternsAndSeparators() {
        for value in ["*", "?", "*.example.com", "a b", "a\tb", "a,b", "a!b",
                      "a\"b", "", "a\nb"] {
            XCTAssertFalse(SSHConfigValue.isSafeAlias(value),
                           "should refuse \(value.debugDescription)")
        }
    }

    // MARK: - Keywords

    func testAnExtraOptionKeywordCannotWriteTwoTokens() {
        var config = HangarConfig.standard()
        config.overrides = [HangarConfig.Override(
            match: ["product": "payments"], user: nil, identityFile: nil,
            knownHostsFile: nil, strictHostKeyChecking: nil,
            extraOptions: ["ProxyJump bastion\n  ProxyCommand": "evil",
                           "ProxyJump": "bastion.example.com"])]
        let text = SSHConfigWriter(config: config).render(
            instances: [Fixture.instance(["product": "payments", "Name": "web",
                                          "hostname": "web.example.com"])],
            region: "us-west-2")
        XCTAssertFalse(text.contains("ProxyCommand"), text)
        XCTAssertTrue(text.contains("ProxyJump bastion.example.com"),
                      "the legitimate option still lands")
    }

    func testSafeKeyword() {
        XCTAssertTrue(SSHConfigValue.isSafeKeyword("ProxyJump"))
        XCTAssertFalse(SSHConfigValue.isSafeKeyword("Proxy Jump"))
        XCTAssertFalse(SSHConfigValue.isSafeKeyword("Proxy-Jump"))
        XCTAssertFalse(SSHConfigValue.isSafeKeyword(""))
    }

    // MARK: - File modes

    func testSyncTightensAFileThatAlreadyExistedTooLoose() throws {
        // replaceItemAt keeps the destination's metadata, so a pre-existing 0644
        // file stayed 0644 however tight the temporary file was.
        let target = path("hangar")
        FileManager.default.createFile(atPath: target, contents: Data("stale\n".utf8),
                                       attributes: [.posixPermissions: 0o644])
        _ = try SSHConfigWriter(config: .standard()).sync(
            instances: [Fixture.instance(["Name": "web", "hostname": "web.example.com"])],
            region: "us-west-2", to: target)
        let mode = try FileManager.default
            .attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testPrivateFileIsCreatedAt0600NotTightenedAfterwards() throws {
        let target = path("secret.json")
        XCTAssertTrue(PrivateFile.write(Data("{}".utf8), to: target))
        let mode = try FileManager.default
            .attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testPrivateFileTightensAnExistingLooseFile() throws {
        let target = path("loose.json")
        FileManager.default.createFile(atPath: target, contents: Data("old".utf8),
                                       attributes: [.posixPermissions: 0o644])
        XCTAssertTrue(PrivateFile.write(Data("new".utf8), to: target))
        let mode = try FileManager.default
            .attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testEnsureDirectoryTightensADirectoryThatAlreadyExists() throws {
        // createDirectory(attributes:) does not change an existing directory, so a
        // hand-made `mkdir ~/.hangar` left the cache's creation window exposed.
        let directory = path("state")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        PrivateFile.ensureDirectory(directory)
        let mode = try FileManager.default
            .attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }
}
