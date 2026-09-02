import XCTest
@testable import HangarCore

/// `credential_process` is arbitrary code from the user's own AWS config, and a
/// helper that never returns used to mean a Hangar that never returns: the setup
/// window sat on "Checking your setup" with nothing under it, and the fleet
/// refreshed forever. It gets a deadline.
final class CredentialProcessTests: XCTestCase {

    func testReadsTheCredentialsAHelperPrints() throws {
        let json = #"{"Version":1,"AccessKeyId":"AKIAEXAMPLE","SecretAccessKey":"s3cret"}"#
        let credentials = try CredentialResolver.runCredentialProcess(
            "printf '%s' '\(json)'")
        XCTAssertEqual(credentials.accessKeyId, "AKIAEXAMPLE")
        XCTAssertEqual(credentials.secretAccessKey, "s3cret")
        XCTAssertNil(credentials.sessionToken)
    }

    func testAHelperThatHangsIsKilledAtTheDeadline() {
        let started = Date()
        XCTAssertThrowsError(
            try CredentialResolver.runCredentialProcess("sleep 30", timeout: 0.4)
        ) { error in
            guard case HangarError.timedOut(let message) = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
            XCTAssertTrue(message.contains("credential_process"))
        }
        // The deadline is the point: it has to return in about the time it was
        // given, not in about the time the helper wanted.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the deadline did not end the wait")
    }

    func testANonZeroExitIsReportedRatherThanTimingOut() {
        XCTAssertThrowsError(
            try CredentialResolver.runCredentialProcess("exit 3", timeout: 5)
        ) { error in
            guard case HangarError.malformedResponse(let message) = error else {
                return XCTFail("expected a malformed response, got \(error)")
            }
            XCTAssertTrue(message.contains("exited 3"))
        }
    }

    func testUnusableJSONIsReported() {
        XCTAssertThrowsError(
            try CredentialResolver.runCredentialProcess("echo not-json", timeout: 5)
        ) { error in
            guard case HangarError.malformedResponse = error else {
                return XCTFail("expected a malformed response, got \(error)")
            }
        }
    }

    func testTheDefaultDeadlineLeavesRoomForAHardwareToken() {
        // Long enough to touch a key, short enough to be a deadline.
        XCTAssertGreaterThanOrEqual(CredentialResolver.credentialProcessTimeout, 15)
        XCTAssertLessThanOrEqual(CredentialResolver.credentialProcessTimeout, 60)
    }
}
