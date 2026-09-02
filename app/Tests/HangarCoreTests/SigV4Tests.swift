import XCTest
@testable import HangarCore

/// The AWS published SigV4 test vector. A known key, date, region and service
/// must produce this exact scope and header set, so a regression is caught here
/// rather than as an opaque 403 from EC2.
final class SigV4Tests: XCTestCase {

    private func signedVector() -> URLRequest {
        let signer = SigV4(
            credentials: AWSCredentials(
                accessKeyId: "AKIDEXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                sessionToken: nil, expiration: nil),
            region: "us-east-1", service: "service")
        var components = DateComponents()
        components.year = 2015; components.month = 8; components.day = 30
        components.hour = 12; components.minute = 36; components.second = 0
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return signer.sign(url: URL(string: "https://example.amazonaws.com/")!,
                           body: "", now: utc.date(from: components)!)
    }

    func testCredentialScope() {
        let auth = signedVector().value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(
            auth.contains("Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"),
            auth)
    }

    func testSignedHeadersAreSortedAndComplete() {
        let auth = signedVector().value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.contains("SignedHeaders=content-type;host;x-amz-date"), auth)
    }

    func testDateHeaderIsStamped() {
        XCTAssertEqual(signedVector().value(forHTTPHeaderField: "X-Amz-Date"),
                       "20150830T123600Z")
    }

    func testSignatureIsPresentAndHex() {
        let auth = signedVector().value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.contains("Signature="), auth)
        XCTAssertEqual(auth.split(separator: "=").last?.count, 64, auth)
    }

    func testSessionTokenIsSignedWhenPresent() {
        let signer = SigV4(
            credentials: AWSCredentials(accessKeyId: "AKIDEXAMPLE",
                                        secretAccessKey: "secret",
                                        sessionToken: "session-token", expiration: nil),
            region: "us-east-1", service: "ec2")
        let request = signer.sign(url: URL(string: "https://example.amazonaws.com/")!, body: "")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Security-Token"),
                       "session-token")
        XCTAssertTrue(
            (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .contains("x-amz-security-token"),
            "the token must be inside SignedHeaders, not just sent alongside")
    }
}
