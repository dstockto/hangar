import XCTest
@testable import HangarCore

final class SSHConfigImportTests: TemporaryDirectoryTestCase {

    private func load(_ text: String, excluding excluded: String = "/nowhere") -> SSHConfigImport.Result {
        let file = path("config")
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
        return SSHConfigImport.load(path: file, excluding: excluded)
    }

    // MARK: - What is a host

    func testReadsHostNameUserAndPort() {
        let result = load("""
        Host bastion
          HostName bastion.example.com
          User ec2-user
          Port 2222
        """)
        XCTAssertEqual(result.hosts.count, 1)
        let host = result.hosts[0]
        XCTAssertEqual(host.aliasStem, "bastion")
        XCTAssertEqual(host.host, "bastion.example.com")
        XCTAssertEqual(host.tags["ssh_config_user"], "ec2-user")
        XCTAssertEqual(host.tags["ssh_config_port"], "2222")
        XCTAssertEqual(host.origin, .sshConfig)
    }

    /// A pattern is not a host. `Host *` is a defaults block, and importing it
    /// would put a host in the menu that matches everything and connects to
    /// nothing.
    func testSkipsPatternsRatherThanImportingThem() {
        let result = load("""
        Host *
          ServerAliveInterval 60

        Host prod-*
          User ec2-user

        Host db1
          HostName 10.0.0.9
        """)
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["db1"])
        XCTAssertEqual(result.skipped.count, 2)
    }

    /// A Match block cannot be evaluated without knowing the user, the host and
    /// the result of any exec, so guessing would produce an alias that resolves
    /// to something other than what it says.
    func testSkipsMatchBlocksWhole() {
        let result = load("""
        Match host *.internal exec "true"
          HostName jumped.example.com
          User root

        Host web1
          HostName 10.0.0.1
        """)
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["web1"])
        XCTAssertTrue(result.skipped.contains { $0.hasPrefix("Match block skipped") })
    }

    func testNeverImportsHangarsOwnFile() {
        let own = path("hangar")
        try? "Host generated-1\n  HostName 10.0.0.5\n"
            .write(toFile: own, atomically: true, encoding: .utf8)
        let result = load("""
        Include \(own)

        Host mine
          HostName 10.0.0.6
        """, excluding: own)
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["mine"],
                       "importing our own output would grow the fleet on every refresh")
    }

    func testFollowsIncludes() {
        let extra = path("extra")
        try? "Host from-include\n  HostName 10.0.0.7\n"
            .write(toFile: extra, atomically: true, encoding: .utf8)
        let result = load("Include \(extra)\n\nHost direct\n  HostName 10.0.0.8\n")
        XCTAssertEqual(Set(result.hosts.map(\.aliasStem)), ["from-include", "direct"])
    }

    func testAnIncludeLoopTerminates() {
        let a = path("a")
        try? "Include \(a)\nHost looped\n  HostName 10.0.0.1\n"
            .write(toFile: a, atomically: true, encoding: .utf8)
        let result = SSHConfigImport.load(path: a, excluding: "/nowhere")
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["looped"])
    }

    func testKeywordSeparatorsSshAcceptsAreAccepted() {
        let result = load("""
        host=web1
        \tHostName\t=\t10.0.0.1
        """)
        XCTAssertEqual(result.hosts.first?.host, "10.0.0.1")
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let result = load("""
        # my hosts
        Host web1   # the web box
          HostName 10.0.0.1
        """)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].aliasStem, "web1")
    }

    func testABlockWithNoHostNameUsesItsOwnAlias() {
        let result = load("Host db.example.com\n  User postgres\n")
        XCTAssertEqual(result.hosts.first?.host, "db.example.com")
    }

    func testExtraNamesOnTheHostLineStaySearchable() {
        let result = load("Host db1 database1 db-primary\n  HostName 10.0.0.9\n")
        XCTAssertEqual(result.hosts.first?.aliasStem, "db1")
        XCTAssertEqual(result.hosts.first?.tags["aliases"], "database1 db-primary")
    }

    // MARK: - Git remotes are not hosts

    /// `ssh git@github.com` prints a greeting and exits. These entries are
    /// credentials for a git remote, and almost every developer has two or three.
    func testGitForgesAreNotImportedAsHosts() {
        let result = load("""
        Host github-personal
          HostName github.com
          IdentityFile ~/.ssh/id_ed25519

        Host bitbucket.org
          HostName bitbucket.org

        Host work-gitlab
          HostName gitlab.internal.example.com
          User git

        Host codecommit
          HostName git-codecommit.us-west-2.amazonaws.com

        Host web1
          HostName 10.0.0.1
          User ec2-user
        """)
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["web1"])
        XCTAssertEqual(result.skipped.filter { $0.contains("git remote") }.count, 4)
    }

    /// Reported, never silently dropped, so someone who really does keep a shell
    /// host behind `User git` can see why it is missing.
    func testASkippedGitRemoteSaysWhy() {
        let result = load("Host github.com\n  HostName github.com\n")
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("not a host you can ssh into"))
    }

    /// The rule is `User git`, not "the name contains git". A build box called
    /// git-runner-1 that you log into as yourself is a host.
    func testAMachineNamedForGitIsStillAHost() {
        let result = load("""
        Host git-runner-1
          HostName 10.0.0.5
          User ec2-user
        """)
        XCTAssertEqual(result.hosts.map(\.aliasStem), ["git-runner-1"])
    }

    // MARK: - Tags from names

    func testEnvComesOnlyFromAKnownWord() {
        let result = load("""
        Host payments-prod-web-1
          HostName 10.0.0.1
        Host payments-banana-web-2
          HostName 10.0.0.2
        """)
        let byAlias = Dictionary(uniqueKeysWithValues: result.hosts.map { ($0.aliasStem, $0) })
        XCTAssertEqual(byAlias["payments-prod-web-1"]?.env, "prod")
        XCTAssertEqual(byAlias["payments-banana-web-2"]?.env, "",
                       "a wrong env on a production box is worse than a blank one")
    }

    /// A leading component is only a grouping if more than one host shares it.
    /// Promoting a component that appears once fills the menu with groups of one.
    func testProductNeedsMoreThanOneHostToBeAProduct() {
        let shared = load("""
        Host payments-prod-web
          HostName 10.0.0.1
        Host payments-prod-db
          HostName 10.0.0.2
        Host lonely-prod-thing
          HostName 10.0.0.3
        """)
        let byAlias = Dictionary(uniqueKeysWithValues: shared.hosts.map { ($0.aliasStem, $0) })
        XCTAssertEqual(byAlias["payments-prod-web"]?.product, "payments")
        XCTAssertEqual(byAlias["lonely-prod-thing"]?.product, "")
    }

    func testDottedNamesUseTheRegistrableLabel() {
        let result = load("""
        Host web1.prod.example.com
          HostName 10.0.0.1
        Host web2.prod.example.com
          HostName 10.0.0.2
        """)
        let host = result.hosts.first { $0.aliasStem == "web1.prod.example.com" }
        XCTAssertEqual(host?.env, "prod")
        XCTAssertEqual(host?.product, "example")
        XCTAssertEqual(host?.role, "web1")
    }

    func testAHostWithNothingToStripKeepsItsWholeName() {
        let result = load("Host bastion\n  HostName 10.0.0.1\n")
        XCTAssertEqual(result.hosts.first?.role, "bastion",
                       "a blank row in the menu is worse than a repeated one")
    }

    // MARK: - Never written back

    func testImportedHostsAreNeverWrittenToHangarsFile() {
        let result = load("Host mine\n  HostName 10.0.0.1\n")
        let writer = SSHConfigWriter(config: .standard())
        XCTAssertTrue(writer.entries(for: result.hosts).isEmpty,
                      "a second definition above the user's own would silently outrank it")
        XCTAssertTrue(writer.omitted(from: result.hosts).isEmpty,
                      "not writing them on purpose is not the same as dropping them")
    }
}
