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

    // MARK: - How each profile authenticates

    /// The picker and the resolve read this from one place, so classifying a
    /// profile wrongly here would mean describing it wrongly on screen too.
    func testEachProfileIsClassifiedTheWayTheResolverWouldTryIt() throws {
        let files = try awsFiles()
        XCTAssertEqual(try files.profile(named: "legacy").method, .staticKeys)
        XCTAssertEqual(try files.profile(named: "sso-admin").method, .sso)
        XCTAssertEqual(try files.profile(named: "stepped").method, .assumedRole)
        XCTAssertEqual(try files.profile(named: "helper").method, .credentialProcess)
        XCTAssertEqual(try files.profile(named: "inline-comment").method, .unavailable,
                       "a region and nothing else is not a credential")
    }

    /// A profile Hangar cannot use is still offered, labelled. Hiding it makes a
    /// mis-set AWS_PROFILE invisible.
    func testSummariesListEveryProfileIncludingTheUnusableOnes() throws {
        let summaries = try awsFiles().profileSummaries
        XCTAssertEqual(summaries.map(\.name), try awsFiles().profileNames)
        let unusable = summaries.first { $0.name == "inline-comment" }
        XCTAssertEqual(unusable?.isUsable, false)
        XCTAssertEqual(unusable?.detail, "no credentials")
        let keys = summaries.first { $0.name == "legacy" }
        XCTAssertEqual(keys?.isUsable, true)
        XCTAssertTrue(keys?.detail.contains("static keys") == true, keys?.detail ?? "")
        XCTAssertTrue(keys?.detail.contains("us-west-2") == true, keys?.detail ?? "")
    }

    func testAutomaticFollowsAWSProfileThenDefault() {
        XCTAssertEqual(
            AWSConfigFiles.activeProfileName(requested: nil, env: [:]), "default")
        XCTAssertEqual(
            AWSConfigFiles.activeProfileName(requested: nil, env: ["AWS_PROFILE": "work"]),
            "work")
        XCTAssertEqual(
            AWSConfigFiles.activeProfileName(requested: "picked",
                                             env: ["AWS_PROFILE": "work"]),
            "picked", "an explicit pick outranks the environment")
    }

    /// Exported keys shadow every profile, so naming one as active would be a
    /// lie: the resolve would not read it.
    func testExportedKeysMeanNoProfileIsActive() {
        let env = ["AWS_ACCESS_KEY_ID": "EXAMPLE", "AWS_SECRET_ACCESS_KEY": "not-real"]
        XCTAssertNil(AWSConfigFiles.activeProfileName(requested: nil, env: env))
        XCTAssertEqual(
            AWSConfigFiles.activeProfileName(requested: "picked", env: env), "picked",
            "asking for a profile is what turns the exported keys off")
    }

    func testAProfileWithNoCredentialsFailsWithItsOwnError() async throws {
        let files = try awsFiles()
        do {
            _ = try await CredentialResolver.resolve(profile: "inline-comment",
                                                     files: files)
            XCTFail("a profile with no credentials should not resolve")
        } catch HangarError.noCredentials(let name) {
            XCTAssertEqual(name, "inline-comment")
        }
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

/// The rest of the DescribeInstances response, which Hangar used to throw away.
final class InstanceDetailParsingTests: XCTestCase {

    func testTheParserKeepsWhatTheHostRecordShows() throws {
        let xml = """
        <DescribeInstancesResponse>
          <reservationSet><item><instancesSet><item>
            <instanceId>i-0abc</instanceId>
            <imageId>ami-0123</imageId>
            <instanceState><name>running</name></instanceState>
            <privateDnsName>ip-10-0-0-1.ec2.internal</privateDnsName>
            <keyName>deploy-key</keyName>
            <instanceType>m6i.large</instanceType>
            <launchTime>2026-08-01T12:00:00.000Z</launchTime>
            <placement><availabilityZone>us-west-2a</availabilityZone></placement>
            <monitoring><state>disabled</state></monitoring>
            <subnetId>subnet-9</subnetId>
            <vpcId>vpc-7</vpcId>
            <privateIpAddress>10.0.0.1</privateIpAddress>
            <architecture>x86_64</architecture>
            <rootDeviceType>ebs</rootDeviceType>
            <instanceLifecycle>spot</instanceLifecycle>
            <iamInstanceProfile><arn>arn:aws:iam::123456789012:instance-profile/app-role</arn></iamInstanceProfile>
            <groupSet>
              <item><groupId>sg-1</groupId><groupName>web</groupName></item>
              <item><groupId>sg-2</groupId><groupName>bastion</groupName></item>
            </groupSet>
            <platformDetails>Linux/UNIX</platformDetails>
            <cpuOptions><coreCount>1</coreCount><threadsPerCore>2</threadsPerCore></cpuOptions>
            <tagSet><item><key>Name</key><value>web-1</value></item></tagSet>
          </item></instancesSet></item></reservationSet>
        </DescribeInstancesResponse>
        """
        let page = try InstanceParser().parse(Data(xml.utf8))
        let host = try XCTUnwrap(page.instances.first)
        XCTAssertEqual(host.imageID, "ami-0123")
        XCTAssertEqual(host.vpcID, "vpc-7")
        XCTAssertEqual(host.subnetID, "subnet-9")
        XCTAssertEqual(host.keyName, "deploy-key")
        XCTAssertEqual(host.iamProfile, "app-role", "the name, not the whole ARN")
        XCTAssertEqual(host.architecture, "x86_64")
        XCTAssertEqual(host.lifecycle, "spot")
        XCTAssertEqual(host.securityGroups, ["web", "bastion"])
        XCTAssertEqual(host.privateDNS, "ip-10-0-0-1.ec2.internal")
        XCTAssertEqual(host.monitoring, "disabled")
        XCTAssertEqual(host.rootDeviceType, "ebs")
        XCTAssertEqual(host.vcpus, 2)
    }

    func testAResponseWithoutTheExtrasStillParses() throws {
        let xml = """
        <DescribeInstancesResponse><reservationSet><item><instancesSet><item>
          <instanceId>i-0abc</instanceId>
          <instanceState><name>running</name></instanceState>
          <instanceType>t3.small</instanceType>
          <launchTime>2026-08-01T12:00:00.000Z</launchTime>
        </item></instancesSet></item></reservationSet></DescribeInstancesResponse>
        """
        let host = try XCTUnwrap(InstanceParser().parse(Data(xml.utf8)).instances.first)
        XCTAssertEqual(host.id, "i-0abc")
        XCTAssertNil(host.imageID)
        XCTAssertNil(host.vcpus)
        XCTAssertNil(host.securityGroups)
    }
}
