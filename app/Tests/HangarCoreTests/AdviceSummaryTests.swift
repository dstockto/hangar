import XCTest
@testable import HangarCore

/// A failure has to be sayable in a strip 640 points wide that already spends
/// 210 of them on hints. The sentence is right for the menu and wrong for the
/// footer, where it was drawn straight through the hints and off the left edge.
final class AdviceSummaryTests: XCTestCase {

    /// What fits beside the hints at the panel's *minimum* width, next to the
    /// "n of n" count. A summary that embeds a profile name is not bounded by
    /// this and so is not a summary; the name belongs in the sentence.
    private let strip = 25

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
    private let rejected = HangarError.http(403, "AccessDenied")

    // MARK: - The reported case

    func testTheSSOSummaryNamesTheCauseWithoutTheCommand() {
        let advice = CredentialAdvice.forFailure(
            HangarError.ssoTokenExpired("aws-developer-collect"),
            profile: profile("aws-developer-collect", sso: true))
        XCTAssertEqual(advice.summary, "SSO session expired")
        // The sentence is what overflowed, and it is still there for the menu.
        XCTAssertTrue(advice.message.contains("aws sso login --profile aws-developer-collect"))
        XCTAssertGreaterThan(advice.message.count, advice.summary.count)
    }

    // MARK: - Every advice fits

    func testEverySummaryFitsTheStrip() {
        let long = "aws-developer-collect"
        let cases: [CredentialAdvice.Advice] = [
            CredentialAdvice.forFailure(HangarError.ssoTokenExpired(long),
                                        profile: profile(long, sso: true)),
            CredentialAdvice.forFailure(expired, profile: profile(long, sso: true)),
            CredentialAdvice.forFailure(
                expired, profile: profile(long, roleArn: "arn:aws:iam::123456789012:role/Admin",
                                          sourceProfile: "default")),
            CredentialAdvice.forFailure(
                rejected, profile: profile(long, roleArn: "arn:aws:iam::123456789012:role/Admin",
                                           sourceProfile: "default")),
            CredentialAdvice.forFailure(
                expired, profile: profile(long, credentialProcess: "/usr/local/bin/creds")),
            CredentialAdvice.forFailure(
                expired, profile: profile(long, staticKeys: true, sessionToken: "t")),
            CredentialAdvice.forFailure(expired, profile: profile(long, staticKeys: true)),
            CredentialAdvice.forFailure(rejected, profile: profile(long, staticKeys: true)),
            CredentialAdvice.forFailure(HangarError.noCredentials(profile: long), profile: nil),
            CredentialAdvice.forFailure(HangarError.noCredentials(profile: long), profile: nil,
                                        alternatives: ["a", "b", "c", "d", "e"]),
            CredentialAdvice.forEnvironmentFailure(expired),
        ]
        for advice in cases {
            XCTAssertLessThanOrEqual(
                advice.summary.count, strip,
                "summary too long for the footer strip: \(advice.summary)")
            XCTAssertFalse(advice.summary.isEmpty)
            // A label, not prose: the sentence lives in the tooltip.
            XCTAssertFalse(advice.summary.hasSuffix("."), advice.summary)
        }
    }

    // MARK: - The fallback, for a raw error nobody wrote a summary for

    func testAnUnrecognisedErrorSummarisesToItsFirstSentence() {
        let advice = CredentialAdvice.forFailure(
            HangarError.malformedResponse("The request timed out. Check your connection "
                                          + "and try again in a few moments."),
            profile: nil)
        XCTAssertEqual(advice.summary, "Unexpected response: The request timed out")
    }

    func testASingleSentenceIsNotCutAtItsOwnFullStop() {
        XCTAssertEqual(CredentialAdvice.firstSentence("No hosts from any source."),
                       "No hosts from any source")
    }

    func testAnAbbreviationDoesNotEndTheSentence() {
        // "Profile a.b" would otherwise summarise to "Profile a", which names
        // the wrong thing rather than merely a shorter thing.
        XCTAssertEqual(CredentialAdvice.firstSentence("Profile a.b has no credentials"),
                       "Profile a.b has no credentials")
    }

    func testTextWithNoSentenceEndSurvivesWhole() {
        XCTAssertEqual(CredentialAdvice.firstSentence("Could not reach EC2"),
                       "Could not reach EC2")
    }

    func testSurroundingWhitespaceIsNotPartOfTheSummary() {
        XCTAssertEqual(CredentialAdvice.firstSentence("  Token expired. Refresh it.  "),
                       "Token expired")
    }

    // MARK: - An explicit summary wins over the derived one

    func testAnExplicitSummaryIsKept() {
        let advice = CredentialAdvice.Advice(message: "A long sentence that would be cut.",
                                             summary: "Short cause")
        XCTAssertEqual(advice.summary, "Short cause")
    }
}
