import XCTest
@testable import HangarCore

final class HostSourceTests: XCTestCase {

    private func host(_ id: String, alias: String?, hostname: String,
                      source: HostSource) -> Instance {
        Instance(id: id, state: "running", type: "", privateIP: nil, publicIP: nil,
                 availabilityZone: nil, launchTime: "",
                 tags: ["hostname": hostname, "Name": alias ?? id],
                 source: source, preferredAlias: alias)
    }

    func testOnlySSHConfigIsLeftUnwritten() {
        XCTAssertTrue(HostSource.ec2.writesSSHConfig)
        XCTAssertTrue(HostSource.ssm.writesSSHConfig)
        XCTAssertTrue(HostSource.hostsFile.writesSSHConfig)
        XCTAssertFalse(HostSource.sshConfig.writesSSHConfig,
                       "those hosts are already resolvable; a second copy would outrank them")
    }

    // MARK: - Merging

    func testEC2WinsOverEverythingForTheSameMachine() {
        let merged = FleetMerge.merge([
            .sshConfig: [host("ssh:web1", alias: "web1", hostname: "10.0.0.1",
                              source: .sshConfig)],
            .ec2: [host("i-0aaa", alias: nil, hostname: "10.0.0.1", source: .ec2)],
        ])
        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(merged.instances[0].origin, .ec2,
                       "the copy that knows the most keeps its tags and its state")
        XCTAssertEqual(merged.duplicates, 1)
    }

    func testSameInstanceIdFromEC2AndSSMIsOneHost() {
        let merged = FleetMerge.merge([
            .ssm: [host("i-0aaa", alias: nil, hostname: "10.0.0.9", source: .ssm)],
            .ec2: [host("i-0aaa", alias: nil, hostname: "10.0.0.1", source: .ec2)],
        ])
        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(merged.instances[0].origin, .ec2)
    }

    func testAliasCollisionAcrossSourcesKeepsThePriorityCopy() {
        let merged = FleetMerge.merge([
            .sshConfig: [host("ssh:web1", alias: "web1", hostname: "10.9.9.9",
                              source: .sshConfig)],
            .hostsFile: [host("csv:web1", alias: "web1", hostname: "10.8.8.8",
                              source: .hostsFile)],
        ])
        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(merged.instances[0].origin, .hostsFile,
                       "the hosts file outranks the ssh config")
    }

    func testDistinctHostsFromEverySourceAllSurvive() {
        let merged = FleetMerge.merge([
            .ec2: [host("i-0aaa", alias: nil, hostname: "10.0.0.1", source: .ec2)],
            .ssm: [host("mi-0bbb", alias: nil, hostname: "10.0.0.2", source: .ssm)],
            .hostsFile: [host("csv:c", alias: "c", hostname: "10.0.0.3", source: .hostsFile)],
            .sshConfig: [host("ssh:d", alias: "d", hostname: "10.0.0.4", source: .sshConfig)],
        ])
        XCTAssertEqual(merged.instances.count, 4)
        XCTAssertEqual(merged.duplicates, 0)
    }

    /// Two members of one autoscaling group share a derived stem by design, and
    /// the writer exists to number them apart. Matching on the stem here dropped
    /// 18 of 223 hosts on a live fleet, silently.
    func testAutoscalingGroupMembersAreNotMergedIntoOne() {
        let a = Fixture.instance(["product": "payments", "env": "prod", "Name": "xfer",
                                  "aws:autoscaling:groupName": "x-prod"],
                                 id: "i-0aaaaaaaaaaaaaaaa")
        var b = Fixture.instance(["product": "payments", "env": "prod", "Name": "xfer",
                                  "aws:autoscaling:groupName": "x-prod"],
                                 id: "i-0bbbbbbbbbbbbbbbb")
        b.privateIP = "10.0.0.2"
        XCTAssertEqual(a.aliasStem, b.aliasStem, "the premise: they share a stem")
        let merged = FleetMerge.merge([.ec2: [a, b]])
        XCTAssertEqual(merged.instances.count, 2)
        XCTAssertEqual(merged.duplicates, 0)
    }

    /// A CSV and an ssh config both hand a host an explicit name, and two hosts
    /// cannot answer to the same one.
    func testAnExplicitNameStillDeduplicates() {
        let merged = FleetMerge.merge([
            .hostsFile: [host("csv:web1", alias: "web1", hostname: "10.0.0.1",
                              source: .hostsFile)],
            .sshConfig: [host("ssh:web1", alias: "web1", hostname: "10.0.0.2",
                              source: .sshConfig)],
        ])
        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(merged.instances[0].origin, .hostsFile)
    }

    func testSourceIsStampedOnEveryHostByTheMerge() {
        let unstamped = Instance(id: "x", state: "running", type: "", privateIP: nil,
                                 publicIP: nil, availabilityZone: nil, launchTime: "",
                                 tags: [:])
        let merged = FleetMerge.merge([.ssm: [unstamped]])
        XCTAssertEqual(merged.instances[0].origin, .ssm)
    }

    // MARK: - Defaults

    func testEverySourceIsOnByDefaultAndSSMWaitsForAFailure() {
        let settings = SourceSettings.standard
        XCTAssertTrue(settings.wantsEC2)
        XCTAssertTrue(settings.wantsSSHConfig)
        XCTAssertTrue(settings.wantsHostsFile)
        XCTAssertFalse(settings.wantsSSMAlways, "an account with EC2 read pays nothing for SSM")
        XCTAssertTrue(settings.wantsSSMAfterFailure)
    }

    func testAPreEXistingCacheStillDecodesAsEC2() throws {
        let json = """
        {"id":"i-0aaa","state":"running","type":"t3.small","launchTime":"","tags":{}}
        """
        let instance = try JSONDecoder().decode(Instance.self, from: Data(json.utf8))
        XCTAssertEqual(instance.origin, .ec2,
                       "a cache written before provenance existed has to keep working")
        XCTAssertTrue(instance.isWrittenToSSHConfig)
    }

    func testAPreferredAliasIsNotSlugified() {
        let instance = host("csv:web1.prod.example.com", alias: "web1.prod.example.com",
                            hostname: "10.0.0.1", source: .hostsFile)
        XCTAssertEqual(instance.aliasStem, "web1.prod.example.com",
                       "slugifying it would produce a name ssh cannot resolve")
    }
}
