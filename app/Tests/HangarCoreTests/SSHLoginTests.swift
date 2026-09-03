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
