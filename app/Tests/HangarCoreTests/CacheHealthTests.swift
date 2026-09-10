import XCTest
@testable import HangarCore

/// The menubar glyph is the only thing most of the day that says whether the
/// fleet on screen is real. It was amber almost permanently because a pulse frame
/// outlived the refresh that started it; these pin the states it may report.
final class CacheHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func health(minutesOld: Double, isRefreshing: Bool = false,
                        lastFetchFailed: Bool = false,
                        hasHosts: Bool = true,
                        staleAfter: Int = 60, healthyWithin: Int = 24) -> CacheHealth {
        CacheHealth.classify(fetchedAt: now.addingTimeInterval(-minutesOld * 60),
                             now: now, isRefreshing: isRefreshing,
                             lastFetchFailed: lastFetchFailed, hasHosts: hasHosts,
                             staleAfterMinutes: staleAfter,
                             healthyWithinHours: healthyWithin)
    }

    func testAFreshCacheIsFresh() {
        XCTAssertEqual(health(minutesOld: 5), .fresh)
    }

    /// The default refresh interval is 30 minutes, so a cache that is merely due
    /// for a refresh is still fresh. Only an interval that was missed is aging.
    func testDueForARefreshIsNotYetAging() {
        XCTAssertEqual(health(minutesOld: 31), .fresh)
    }

    func testAgingStartsAtTheHour() {
        XCTAssertEqual(health(minutesOld: 59), .fresh)
        XCTAssertEqual(health(minutesOld: 60), .aging)
        XCTAssertEqual(health(minutesOld: 23 * 60), .aging)
    }

    func testStaleAtTheHealthyWindow() {
        XCTAssertEqual(health(minutesOld: 24 * 60 - 1), .aging)
        XCTAssertEqual(health(minutesOld: 24 * 60), .stale)
    }

    func testAFailedRefreshIsStaleWhateverTheAge() {
        XCTAssertEqual(health(minutesOld: 1, lastFetchFailed: true), .stale)
    }

    /// Refreshing wins over the age underneath: the glyph is reporting that
    /// Hangar is doing something about it, and the tooltip says so.
    func testRefreshingWinsOverAStaleCache() {
        XCTAssertEqual(health(minutesOld: 90 * 60, isRefreshing: true), .refreshing)
    }

    /// Never fetched is not the same claim as out of date. There is no fleet on
    /// screen to call stale, so the glyph makes no colour claim at all.
    func testNothingCachedIsUnknownRatherThanStale() {
        XCTAssertEqual(
            CacheHealth.classify(fetchedAt: nil, now: now, isRefreshing: false,
                                 lastFetchFailed: false, hasHosts: false,
                                 staleAfterMinutes: 60, healthyWithinHours: 24),
            .unknown)
        XCTAssertEqual(health(minutesOld: 5, hasHosts: false), .unknown)
    }

    /// A hand-edited config of zero would otherwise report every cache stale the
    /// instant it was written, which reads as the app being broken.
    func testZeroThresholdsAreClamped() {
        XCTAssertEqual(health(minutesOld: 0.5, staleAfter: 0, healthyWithin: 0), .fresh)
    }

    func testCustomThresholdsAreHonoured() {
        XCTAssertEqual(health(minutesOld: 20, staleAfter: 15), .aging)
        XCTAssertEqual(health(minutesOld: 3 * 60, staleAfter: 15, healthyWithin: 2), .stale)
    }
}
