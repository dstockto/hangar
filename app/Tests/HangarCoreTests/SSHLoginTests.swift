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
        let picked = SSHLogin.probeCandidate(from: [
            host(state: "stopped", platform: "Linux/UNIX"),
            host(state: "running", platform: "Linux/UNIX"),
        ])
        XCTAssertEqual(picked?.state, "running", "a stopped host cannot answer")
    }

    func testWindowsHostsAreNotAsked() {
        XCTAssertNil(SSHLogin.probeCandidate(from: [
            host(state: "running", platform: "Windows"),
        ]), "there is no ssh login to learn")
    }

    /// An imported host is launched from the user's own config, which already
    /// carries its login. Probing it would learn something Hangar will not write.
    func testImportedHostsAreNotAsked() {
        XCTAssertNil(SSHLogin.probeCandidate(from: [
            host(state: "running", platform: "Linux/UNIX", source: .sshConfig),
        ]))
    }

    func testAnEmptyFleetIsNotAsked() {
        XCTAssertNil(SSHLogin.probeCandidate(from: []))
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
