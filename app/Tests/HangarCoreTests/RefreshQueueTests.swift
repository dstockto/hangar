import XCTest
@testable import HangarCore

/// The app's side of `hangar refresh`. Any process in the session can post a
/// request, so these pin how many are held and how one refresh answers them all.
final class RefreshQueueTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    func id(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

    // MARK: - Admission

    func testTheFirstRequestStartsTheAnswer() {
        var queue = RefreshQueue()
        XCTAssertEqual(queue.admit(id(1)), .startsAnswer)
    }

    func testLaterRequestsRideAlong() {
        var queue = RefreshQueue()
        _ = queue.admit(id(1))
        XCTAssertEqual(queue.admit(id(2)), .joined)
        XCTAssertEqual(queue.admit(id(3)), .joined)
        XCTAssertEqual(queue.waiting, [id(1), id(2), id(3)])
    }

    /// A flood is capped, and what is past the cap is not held, so it is never
    /// owed a reply.
    func testRequestsPastTheCapAreDropped() {
        var queue = RefreshQueue()
        for n in 0..<RefreshSignal.mostWaiting {
            XCTAssertNotEqual(queue.admit(id(n)), .dropped)
        }
        XCTAssertEqual(queue.admit(id(999)), .dropped)
        XCTAssertEqual(queue.waiting.count, RefreshSignal.mostWaiting)
        XCTAssertFalse(queue.waiting.contains(id(999)))
    }

    // MARK: - Release

    func testReleaseAnswersEveryoneOnce() {
        var queue = RefreshQueue()
        _ = queue.admit(id(1))
        _ = queue.admit(id(2))
        XCTAssertEqual(queue.release(), [id(1), id(2)])
        XCTAssertEqual(queue.release(), [])
    }

    /// Once an answer has been sent, the next request must not join it: nobody
    /// would ever tell it the result.
    func testARequestAfterReleaseStartsANewAnswer() {
        var queue = RefreshQueue()
        _ = queue.admit(id(1))
        _ = queue.release()
        XCTAssertEqual(queue.admit(id(2)), .startsAnswer)
    }

    /// The cap counts what is held now, not what was ever seen.
    func testReleaseMakesRoomAgain() {
        var queue = RefreshQueue()
        for n in 0..<RefreshSignal.mostWaiting { _ = queue.admit(id(n)) }
        _ = queue.release()
        XCTAssertEqual(queue.admit(id(999)), .startsAnswer)
    }

    // MARK: - Whether the answer fetches

    /// A refresh the timer or the menu started is joined, not doubled.
    func testARunningRefreshIsJoined() {
        var queue = RefreshQueue()
        XCTAssertFalse(queue.startsFetch(isRefreshing: true, fetchedAt: ago(600),
                                         lastFailed: false, now: now))
        XCTAssertNil(queue.lastRequested)
    }

    func testAStaleFleetStartsAFetch() {
        var queue = RefreshQueue()
        XCTAssertTrue(queue.startsFetch(isRefreshing: false, fetchedAt: ago(600),
                                        lastFailed: false, now: now))
        XCTAssertEqual(queue.lastRequested, now)
    }

    /// The spacing comes from the fetch this queue started, so a second request
    /// right behind a failing one does not resolve credentials again.
    func testAFetchSpacesTheNextOne() {
        var queue = RefreshQueue()
        XCTAssertTrue(queue.startsFetch(isRefreshing: false, fetchedAt: ago(600),
                                        lastFailed: true, now: ago(3)))
        XCTAssertFalse(queue.startsFetch(isRefreshing: false, fetchedAt: ago(600),
                                         lastFailed: true, now: now))
        XCTAssertTrue(queue.startsFetch(
            isRefreshing: false, fetchedAt: ago(600), lastFailed: true,
            now: ago(3).addingTimeInterval(RefreshSignal.reuseWithin)))
    }

    func testAFreshFleetAnswersWithoutFetching() {
        var queue = RefreshQueue()
        XCTAssertFalse(queue.startsFetch(isRefreshing: false, fetchedAt: ago(2),
                                         lastFailed: false, now: now))
        XCTAssertNil(queue.lastRequested)
    }

    // MARK: - The reply

    func testAFailureIsReportedAsOne() {
        let reports = [SourceReport(source: .ec2, hosts: 4)]
        XCTAssertEqual(RefreshQueue.reply(failure: "credentials expired", reports: reports),
                       .failed("credentials expired"))
    }

    /// A source that failed while another worked is still a refresh, with a note
    /// that names the source, so nobody mistakes the missing hosts for terminated.
    func testAPartialFailureIsANamedNote() {
        let reports = [
            SourceReport(source: .ec2, hosts: 4),
            SourceReport(source: .sshConfig, problem: "could not be read"),
            .off(.ssm),
        ]
        XCTAssertEqual(RefreshQueue.reply(failure: nil, reports: reports),
                       .finished(notes: ["~/.ssh/config: could not be read"]))
    }

    func testACleanRefreshHasNoNotes() {
        XCTAssertEqual(RefreshQueue.reply(failure: nil,
                                          reports: [SourceReport(source: .ec2, hosts: 4)]),
                       .finished(notes: []))
    }
}
