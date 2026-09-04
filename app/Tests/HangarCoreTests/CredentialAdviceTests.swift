import XCTest
@testable import HangarCore

/// The recovery Hangar suggests has to match how the user actually authenticates.
/// Telling someone with a key pair in ~/.aws/credentials to run `aws sso login`
/// is worse than saying nothing: it sends them somewhere that cannot help.
final class CredentialAdviceTests: XCTestCase {

    private func profile(_ name: String, sso: Bool = false, staticKeys: Bool = false,
                         sessionToken: String? = nil, roleArn: String? = nil,
                         sourceProfile: String? = nil,
                         credentialProcess: String? = nil) -> AWSProfile {
        AWSProfile(
            name: name, region: "us-west-2",
            ssoSessionName: nil,
            ssoAccountId: sso ? "123456789012" : nil,
            ssoRoleName: sso ? "Admin" : nil,
            ssoStartURL: sso ? "https://example.awsapps.com/start" : nil,
            ssoRegion: sso ? "us-east-1" : nil,
            accessKeyId: staticKeys ? "EXAMPLE-KEY-ID" : nil,
            secretAccessKey: staticKeys ? "not-a-real-secret" : nil,
            sessionToken: sessionToken,
            roleArn: roleArn, sourceProfile: sourceProfile, externalId: nil,
            roleSessionName: nil, credentialProcess: credentialProcess)
    }

    private let expired = HangarError.http(403, "The security token included in the "
                                           + "request is expired")

    // MARK: - SSO

    func testSSOProfileGetsTheLoginCommand() {
        let advice = CredentialAdvice.forFailure(
            HangarError.ssoTokenExpired("token expired"),
            profile: profile("work", sso: true))
        XCTAssertEqual(advice.command, "aws sso login --profile work")
        XCTAssertTrue(advice.message.contains("SSO session"), advice.message)
    }

    func testAnSSOErrorIsTrustedEvenWithoutAProfile() {
        let advice = CredentialAdvice.forFailure(
            HangarError.noSSOToken("nothing in the cache"), profile: nil)
        XCTAssertEqual(advice.command, "aws sso login")
    }

    // MARK: - Static keys, the case that was wrong

    func testStaticKeysAreNeverToldToRunSSOLogin() {
        let advice = CredentialAdvice.forFailure(
            expired, profile: profile("legacy", staticKeys: true))
        XCTAssertNil(advice.command, "there is no login command for a key pair")
        XCTAssertFalse(advice.message.lowercased().contains("sso"), advice.message)
    }

    func testAnExpiredSessionTokenPointsAtTheCredentialsFile() {
        let advice = CredentialAdvice.forFailure(
            expired,
            profile: profile("legacy", staticKeys: true, sessionToken: "not-a-real-token"))
        XCTAssertTrue(advice.message.contains("session token"), advice.message)
        XCTAssertTrue(advice.message.contains("~/.aws/credentials"), advice.message)
    }

    func testRejectedKeysSayTheKeyWasRejected() {
        let advice = CredentialAdvice.forFailure(
            HangarError.http(403, "InvalidClientTokenId"),
            profile: profile("legacy", staticKeys: true))
        XCTAssertTrue(advice.message.contains("rejected"), advice.message)
        XCTAssertTrue(advice.message.contains("legacy"), advice.message)
        XCTAssertNil(advice.command)
    }

    // MARK: - Assumed roles and credential_process

    func testAssumeRoleBlamesTheSourceProfile() {
        let advice = CredentialAdvice.forFailure(
            expired,
            profile: profile("stepped", roleArn: "arn:aws:iam::999999999999:role/Ops",
                             sourceProfile: "legacy"))
        XCTAssertTrue(advice.message.contains("legacy"), advice.message)
        XCTAssertTrue(advice.message.contains("Ops"), advice.message)
    }

    func testCredentialProcessSaysToRunItByHand() {
        let advice = CredentialAdvice.forFailure(
            expired, profile: profile("helper", credentialProcess: "/bin/echo {}"))
        XCTAssertTrue(advice.message.contains("credential_process"), advice.message)
        XCTAssertNil(advice.command)
    }

    func testEnvironmentCredentialsPointAtTheEnvironment() {
        let advice = CredentialAdvice.forEnvironmentFailure(expired)
        XCTAssertTrue(advice.message.contains("AWS_ACCESS_KEY_ID"), advice.message)
    }

    // MARK: - Not every failure is a credential problem

    func testAnUnrelatedErrorIsPassedThroughUntouched() {
        let advice = CredentialAdvice.forFailure(
            HangarError.http(503, "Service Unavailable"),
            profile: profile("legacy", staticKeys: true))
        XCTAssertEqual(advice.message, HangarError.http(503, "Service Unavailable")
            .localizedDescription)
        XCTAssertNil(advice.command)
    }

    func testAMissingProfileIsReportedAsItself() {
        let advice = CredentialAdvice.forFailure(
            HangarError.noProfile("no profile 'typo'. Available: default"),
            profile: nil)
        XCTAssertTrue(advice.message.contains("no profile 'typo'"), advice.message)
        XCTAssertNil(advice.command)
    }

    // MARK: - A profile with nothing in it

    /// The answer for someone with three profiles is to pick one, not to go and
    /// write credentials into the one Hangar happened to try.
    func testAProfileWithNoCredentialsNamesTheOnesThatWork() {
        let advice = CredentialAdvice.forFailure(
            HangarError.noCredentials(profile: "default"),
            profile: profile("default"),
            alternatives: ["default", "aws-developer", "aws-admin"])
        XCTAssertTrue(advice.message.contains("aws-developer"), advice.message)
        XCTAssertTrue(advice.message.contains("aws-admin"), advice.message)
        XCTAssertFalse(advice.message.contains("Pick one that does: default"),
                       "the profile that just failed is not an alternative")
        XCTAssertNil(advice.command)
    }

    func testWithNoOtherProfileItSaysWhatAProfileNeeds() {
        let advice = CredentialAdvice.forFailure(
            HangarError.noCredentials(profile: "default"),
            profile: profile("default"),
            alternatives: ["default"])
        XCTAssertTrue(advice.message.contains("key pair"), advice.message)
        XCTAssertTrue(advice.message.contains("credential_process"), advice.message)
    }

    // MARK: - The setup check reflects it

    func testSetupCheckOffersACommandOnlyWhenOneApplies() {
        let sso = Preflight.credentialsCheck(
            sourceLabel: nil,
            advice: CredentialAdvice.forFailure(
                HangarError.ssoTokenExpired("expired"),
                profile: profile("work", sso: true)))
        XCTAssertEqual(sso.remedy, .copyLoginCommand("aws sso login --profile work"))

        let keys = Preflight.credentialsCheck(
            sourceLabel: nil,
            advice: CredentialAdvice.forFailure(
                expired, profile: profile("legacy", staticKeys: true)))
        XCTAssertNil(keys.remedy, "no command to copy for a key pair")
        XCTAssertEqual(keys.title, "Credentials unavailable")
        XCTAssertEqual(keys.level, .problem)
    }

    func testResolvedCredentialsStayFine() {
        let check = Preflight.credentialsCheck(sourceLabel: "SSO profile default",
                                               advice: nil)
        XCTAssertEqual(check.level, .ok)
    }
}
