import XCTest
@testable import HangarCore

final class AWSConfigTests: TemporaryDirectoryTestCase {

    func testFindsProfilesFromBothFiles() throws {
        let names = try awsFiles().profileNames
        XCTAssertTrue(names.contains("default"))
        XCTAssertTrue(names.contains("sso-admin"))
        XCTAssertTrue(names.contains("old-style-only"))
        XCTAssertTrue(names.contains("legacy"))
    }

    func testExcludesSSOSessionBlocks() throws {
        XCTAssertFalse(try awsFiles().profileNames.contains { $0.hasPrefix("sso-session") })
    }

    func testReadsOldStyleCredentialsFile() throws {
        let legacy = try awsFiles().profile(named: "legacy")
        XCTAssertEqual(legacy.accessKeyId, "EXAMPLE-KEY-ID-legacy")
        XCTAssertEqual(legacy.sessionToken, "not-a-real-session-token")
        XCTAssertTrue(legacy.hasStaticKeys)
        XCTAssertFalse(legacy.isSSO)
    }

    func testProfilePresentOnlyInCredentialsFileResolves() throws {
        let only = try awsFiles().profile(named: "old-style-only")
        XCTAssertTrue(only.hasStaticKeys)
        XCTAssertFalse(only.region.isEmpty, "should fall back to a default region")
    }

    func testDefaultProfileSpansBothFiles() throws {
        let files = try awsFiles()
        let profile = try files.profile(named: "default")
        XCTAssertEqual(profile.region, "us-west-2", "region comes from config")
        XCTAssertEqual(profile.accessKeyId, "EXAMPLE-KEY-ID-default",
                       "keys come from credentials")
    }

    func testSSOProfileInheritsFromItsSession() throws {
        let sso = try awsFiles().profile(named: "sso-admin")
        XCTAssertEqual(sso.ssoStartURL, "https://corp.awsapps.com/start/#")
        XCTAssertEqual(sso.ssoRegion, "us-east-1")
        XCTAssertEqual(sso.region, "eu-west-1", "the profile keeps its own region")
        XCTAssertTrue(sso.isSSO)
        XCTAssertFalse(sso.hasStaticKeys)
    }

    func testAssumeRoleProfile() throws {
        let stepped = try awsFiles().profile(named: "stepped")
        XCTAssertEqual(stepped.roleArn, "arn:aws:iam::999999999999:role/Ops")
        XCTAssertEqual(stepped.sourceProfile, "legacy")
        XCTAssertTrue(stepped.assumesRole)
    }

    func testStripsTrailingCommentButKeepsHashInsideAValue() throws {
        let files = try awsFiles()
        XCTAssertEqual(try files.profile(named: "inline-comment").region, "ap-south-1")
        XCTAssertEqual(try files.profile(named: "sso-admin").ssoStartURL?.hasSuffix("#"), true,
                       "an SSO start URL legitimately ends in '#'")
    }

    func testStaticKeysResolveWithoutNetwork() async throws {
        let files = try awsFiles()
        let resolved = try await CredentialResolver.resolve(profile: "legacy", files: files)
        XCTAssertEqual(resolved.credentials.accessKeyId, "EXAMPLE-KEY-ID-legacy")
        XCTAssertEqual(resolved.source, .staticKeys(profile: "legacy"))
        XCTAssertEqual(resolved.region, "us-west-2")
    }

    func testUnknownProfileErrorsUsefully() async throws {
        let files = try awsFiles()
        do {
            _ = try await CredentialResolver.resolve(profile: "does-not-exist", files: files)
            XCTFail("an unknown profile should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no profile"),
                          error.localizedDescription)
        }
    }
}
