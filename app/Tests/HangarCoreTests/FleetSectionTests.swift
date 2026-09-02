import XCTest
@testable import HangarCore

/// The menu must not tell the user their account is empty when the truth is that
/// Hangar never got to look. Those are different problems, and only one of them
/// is fixed by tagging an instance.
final class FleetSectionTests: XCTestCase {

    func testHostsWin() {
        XCTAssertEqual(FleetSection.classify(hostCount: 3, isRefreshing: true,
                                             lastFetchFailed: true,
                                             everReachedAWS: false), .hosts)
    }

    func testEmptyOnlyAfterAWSWasActuallyReached() {
        XCTAssertEqual(FleetSection.classify(hostCount: 0, isRefreshing: false,
                                             lastFetchFailed: false,
                                             everReachedAWS: true), .empty)
    }

    func testAFailedFirstFetchSaysNothing() {
        // The error row and Retry above it are the whole story; "No hosts found"
        // on top of "your SSO session has expired" is a second, false diagnosis.
        XCTAssertEqual(FleetSection.classify(hostCount: 0, isRefreshing: false,
                                             lastFetchFailed: true,
                                             everReachedAWS: false), .hidden)
    }

    func testAFailedRefreshOverACachedEmptyFleetStillReportsEmpty() {
        XCTAssertEqual(FleetSection.classify(hostCount: 0, isRefreshing: false,
                                             lastFetchFailed: true,
                                             everReachedAWS: true), .empty)
    }

    func testTheFirstFetchInFlightSaysSo() {
        XCTAssertEqual(FleetSection.classify(hostCount: 0, isRefreshing: true,
                                             lastFetchFailed: false,
                                             everReachedAWS: false), .looking)
    }

    func testIdleAndNeverFetched() {
        XCTAssertEqual(FleetSection.classify(hostCount: 0, isRefreshing: false,
                                             lastFetchFailed: false,
                                             everReachedAWS: false), .neverFetched)
    }
}
