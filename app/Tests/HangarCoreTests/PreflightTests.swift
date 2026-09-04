import XCTest
@testable import HangarCore

final class PreflightTests: TemporaryDirectoryTestCase {

    func testNoAWSProfilesIsABlocker() {
        let empty = AWSConfigFiles(config: [:], credentials: [:])
        XCTAssertEqual(Preflight.profilesCheck(empty, env: [:]).level, .problem)
    }

    /// Counting the profiles without naming the pick is how a machine with three
    /// of them failed on the one Hangar chose for itself, with nothing on screen
    /// admitting which that was.
    func testProfilesFoundNamesTheOneInUseAndHowItAuthenticates() throws {
        let check = Preflight.profilesCheck(try awsFiles(), using: "legacy", env: [:])
        XCTAssertEqual(check.level, .ok)
        XCTAssertTrue(check.detail.contains("Using legacy"), check.detail)
        XCTAssertTrue(check.detail.contains("static keys"), check.detail)
        XCTAssertTrue(check.detail.contains("Also available"), check.detail)
    }

    func testWithNothingPickedItSaysTheDefaultIsADefault() throws {
        let check = Preflight.profilesCheck(try awsFiles(), env: [:])
        XCTAssertTrue(check.detail.contains("Using default by default"), check.detail)
    }

    /// A name that is in neither file reads as a credentials problem in the error
    /// AWS gives back, when it is simply the wrong name.
    func testAProfileThatIsNotInEitherFileIsCalledOut() throws {
        let check = Preflight.profilesCheck(try awsFiles(), using: "typo", env: [:])
        XCTAssertEqual(check.level, .warning)
        XCTAssertTrue(check.detail.contains("not in ~/.aws/config"), check.detail)
    }

    func testExportedKeysAreReportedRatherThanAProfile() throws {
        let check = Preflight.profilesCheck(
            try awsFiles(),
            env: ["AWS_ACCESS_KEY_ID": "EXAMPLE", "AWS_SECRET_ACCESS_KEY": "not-real"])
        XCTAssertEqual(check.level, .ok)
        XCTAssertTrue(check.detail.contains("reads no profile at all"), check.detail)
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
            Preflight.terminalCheck(configured: .iterm, installed: [.terminal]).level,
            .warning)
        XCTAssertEqual(
            Preflight.terminalCheck(configured: .iterm, installed: []).level, .problem)
        XCTAssertEqual(
            Preflight.terminalCheck(configured: .iterm,
                                    installed: [.iterm, .terminal]).level, .ok)
    }

    /// The check names what else is on the machine, because the picker beside it
    /// is only worth opening if something else is there to pick.
    func testTheTerminalCheckNamesTheOtherTerminalsInstalled() {
        let check = Preflight.terminalCheck(configured: .ghostty,
                                            installed: [.ghostty, .terminal])
        XCTAssertEqual(check.level, .ok)
        XCTAssertTrue(check.title.contains("Ghostty"), check.title)
        XCTAssertTrue(check.detail.contains("Also installed: Terminal"), check.detail)
        XCTAssertFalse(check.detail.contains("permission"),
                       "Ghostty is not scripted, so nothing asks for Automation")
    }

    func testAScriptedTerminalSaysMacOSWillAskForPermission() {
        let check = Preflight.terminalCheck(configured: .iterm, installed: [.iterm])
        XCTAssertTrue(check.detail.contains("permission to control it"), check.detail)
    }

    /// Falling back is not silent: the card says which app will actually open.
    func testAMissingTerminalSaysWhatWillOpenInstead() {
        let check = Preflight.terminalCheck(configured: .ghostty, installed: [.terminal])
        XCTAssertEqual(check.level, .warning)
        XCTAssertTrue(check.detail.contains("open in Terminal instead"), check.detail)
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

    // MARK: - Sources

    /// The headline is the merged fleet, not the sum of the rows. A cluster that
    /// disagrees with the menu was mistake 18; this is the same shape.
    func testSourceHeadlineReportsTheMergedFleetNotTheSum() {
        let check = Preflight.sourcesCheck([
            SourceReport(source: .ec2, hosts: 223),
            SourceReport(source: .sshConfig, hosts: 4),
        ], fleetSize: 225)
        XCTAssertTrue(check.title.contains("225"))
        XCTAssertTrue(check.detail.contains("2 named by two sources"))
    }

    /// A denied EC2 call in front of sources that worked is a note, not a blocker.
    func testADeniedSourceIsAWarningWhenAnotherWorked() {
        let check = Preflight.sourcesCheck([
            SourceReport(source: .ec2, problem: "not authorized"),
            SourceReport(source: .sshConfig, hosts: 41),
        ], fleetSize: 41)
        XCTAssertEqual(check.level, .warning)
        XCTAssertTrue(check.detail.contains("not authorized"))
    }

    /// A credential paragraph on one source used to fill all three lines of this
    /// detail, so the counts the check exists to report were off the card.
    func testALongProblemDoesNotHideTheOtherSourcesCounts() {
        let check = Preflight.sourcesCheck([
            SourceReport(source: .ec2, problem:
                "Profile default has no credentials Hangar can use. Pick one that "
                + "does: aws-developer-collect, aws-development-admin."),
            SourceReport(source: .sshConfig, hosts: 11),
        ], fleetSize: 11)
        XCTAssertTrue(check.detail.contains("~/.ssh/config: 11"), check.detail)
        XCTAssertTrue(check.detail.count < 120, check.detail)
    }

    func testNoHostsAnywhereOffersTheCSVImport() {
        let check = Preflight.sourcesCheck([
            SourceReport(source: .ec2, problem: "not authorized"),
            SourceReport(source: .sshConfig, hosts: 0),
        ], fleetSize: 0)
        XCTAssertEqual(check.level, .problem)
        XCTAssertEqual(check.remedy, .importHostsFile)
    }

    /// Credentials failing used to be the difference between a working app and a
    /// broken one. It is not any more, and calling it a blocker in front of a
    /// fleet that is on screen would be a lie.
    func testExpiredCredentialsAreOnlyABlockerWhenNothingElseWorked() {
        let advice = CredentialAdvice.Advice(
            message: "SSO session expired.", command: "aws sso login")
        XCTAssertEqual(
            Preflight.credentialsCheck(sourceLabel: nil, advice: advice).level, .problem)
        XCTAssertEqual(
            Preflight.credentialsCheck(sourceLabel: nil, advice: advice,
                                       hasHostsAnyway: true).level, .warning)
    }

    // MARK: - Keys

    func testAnAgentHoldingKeysIsReportedAsReady() {
        let agent = SSHAgent(kind: .onePassword, socket: "/tmp/a.sock",
                             keys: [AgentKey(algorithm: "ssh-ed25519",
                                             blob: "AAAAC3NzaC1lZDI1NTE5aaaa1111",
                                             comment: "Prod SRE")])
        let check = Preflight.keyCheck(agents: [agent], keyFiles: [], settings: nil)
        XCTAssertEqual(check.level, .ok)
        XCTAssertTrue(check.title.contains("1Password"))
    }

    /// A locked vault and an empty one look identical from outside, so the remedy
    /// has to be the app rather than an instruction to go find a key.
    func testALockedAgentOffersItsApp() {
        let agent = SSHAgent(kind: .onePassword, socket: "/tmp/a.sock", keys: [],
                             problem: "No keys available.")
        let check = Preflight.keyCheck(agents: [agent], keyFiles: [], settings: nil)
        XCTAssertEqual(check.level, .warning)
        XCTAssertEqual(check.remedy,
                       .openApp(bundleID: "com.1password.1password", name: "1Password"))
    }

    func testKeyFilesAreReportedWithoutClaimingHangarUsesThem() {
        let check = Preflight.keyCheck(agents: [], keyFiles: ["~/.ssh/id_ed25519"],
                                       settings: nil)
        XCTAssertEqual(check.level, .ok)
        XCTAssertTrue(check.detail.contains("id_ed25519"))
    }

    // MARK: - Aliases

    /// Quoting the fleet size here would claim aliases that are not in the file.
    func testTheAliasCountIsWhatWasWrittenNotTheFleetSize() {
        let check = Preflight.sshIncludeCheck(includePresent: true, fileExists: true,
                                              hostCount: 223, importedCount: 2)
        XCTAssertTrue(check.detail.contains("223 Hangar aliases"))
        XCTAssertTrue(check.detail.contains("2 more are already in your own config"))
    }
}
