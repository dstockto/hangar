import XCTest
@testable import HangarCore

final class PreflightTests: TemporaryDirectoryTestCase {

    func testNoAWSProfilesIsABlocker() {
        let empty = AWSConfigFiles(config: [:], credentials: [:])
        XCTAssertEqual(Preflight.profilesCheck(empty).level, .problem)
    }

    func testProfilesFoundIsFine() throws {
        XCTAssertEqual(Preflight.profilesCheck(try awsFiles()).level, .ok)
    }

    func testAMissingIncludeLineWarnsRatherThanBlocks() {
        let check = Preflight.sshIncludeCheck(includePresent: false, fileExists: true,
                                              hostCount: 12)
        XCTAssertEqual(check.level, .warning, "Hangar connects either way")
        XCTAssertEqual(check.remedy, .addIncludeLine)
    }

    func testAnActiveIncludeLineIsFine() {
        XCTAssertEqual(
            Preflight.sshIncludeCheck(includePresent: true, fileExists: true,
                                      hostCount: 12).level, .ok)
    }

    func testTaggingChecks() {
        XCTAssertEqual(Preflight.taggingCheck(instances: []).level, .warning)

        let untagged = [Fixture.instance(["hostname": "box.example.com"], id: "i-0dead")]
        let untaggedCheck = Preflight.taggingCheck(instances: untagged)
        XCTAssertEqual(untaggedCheck.level, .warning)
        XCTAssertTrue(untaggedCheck.detail.contains("untagged"), untaggedCheck.detail)

        let tagged = [Fixture.instance(["product": "payments", "env": "prod", "Name": "web"]),
                      Fixture.instance(["product": "payments", "env": "qa", "Name": "web"])]
        let taggedCheck = Preflight.taggingCheck(instances: tagged)
        XCTAssertEqual(taggedCheck.level, .ok)
        XCTAssertTrue(taggedCheck.detail.contains("environments"), taggedCheck.detail)
    }

    func testTerminalChecks() {
        XCTAssertEqual(
            Preflight.terminalCheck(configured: "iterm", installed: false,
                                    fallbackInstalled: true).level, .warning)
        XCTAssertEqual(
            Preflight.terminalCheck(configured: "iterm", installed: false,
                                    fallbackInstalled: false).level, .problem)
        XCTAssertEqual(
            Preflight.terminalCheck(configured: "iterm", installed: true,
                                    fallbackInstalled: true).level, .ok)
    }

    func testResolvedCredentialsAreFine() {
        XCTAssertEqual(
            Preflight.credentialsCheck(sourceLabel: "SSO profile default",
                                       advice: nil).level, .ok)
    }

    func testWorstLevelAndUsability() {
        let mixed = Preflight(checks: [
            Preflight.Check(id: "a", title: "a", detail: "", level: .ok),
            Preflight.Check(id: "b", title: "b", detail: "", level: .warning),
        ])
        XCTAssertEqual(mixed.worst, .warning)
        XCTAssertTrue(mixed.isUsable, "warnings are optional improvements, not blockers")

        let blocked = Preflight(checks: mixed.checks + [
            Preflight.Check(id: "c", title: "c", detail: "", level: .problem)])
        XCTAssertFalse(blocked.isUsable)
    }
}
