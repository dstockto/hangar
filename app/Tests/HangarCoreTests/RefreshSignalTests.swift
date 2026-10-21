import XCTest
@testable import HangarCore

/// `hangar refresh` asks the app over a distributed notification, which any
/// process in the session can post or answer. These pin what crosses that line.
final class RefreshSignalTests: XCTestCase {

    // MARK: - The request id

    func testAGeneratedIDIsAccepted() {
        XCTAssertTrue(RefreshSignal.isRequestID(UUID().uuidString))
    }

    func testAnythingElseIsNotEchoed() {
        XCTAssertFalse(RefreshSignal.isRequestID(""))
        XCTAssertFalse(RefreshSignal.isRequestID("refresh"))
        XCTAssertFalse(RefreshSignal.isRequestID(UUID().uuidString + "\n"))
        XCTAssertFalse(RefreshSignal.isRequestID(String(repeating: "a", count: 36)))
    }

    // MARK: - Replies

    func testEveryReplySurvivesTheTrip() {
        let replies: [RefreshSignal.Reply] = [
            .started,
            .finished(notes: []),
            .finished(notes: ["EC2: access denied", "SSM: access denied"]),
            .failed("Your SSO session has expired.\nRun aws sso login --profile dev."),
        ]
        for reply in replies {
            XCTAssertEqual(RefreshSignal.reply(from: RefreshSignal.userInfo(for: reply)), reply)
        }
    }

    func testAnUnknownReplyIsIgnored() {
        XCTAssertNil(RefreshSignal.reply(from: nil))
        XCTAssertNil(RefreshSignal.reply(from: [:]))
        XCTAssertNil(RefreshSignal.reply(from: ["state": "exploded"]))
        XCTAssertNil(RefreshSignal.reply(from: ["state": 3]))
    }

    func testAFailureWithNoMessageStillSaysSomething() {
        XCTAssertEqual(RefreshSignal.reply(from: ["state": "failed"]),
                       .failed("the refresh failed"))
        XCTAssertEqual(RefreshSignal.reply(from: ["state": "failed", "message": "\n \n"]),
                       .failed("the refresh failed"))
    }

    /// A reply is printed on the user's terminal, and anything could have sent
    /// it. ESC and CR would let it rewrite what is already on screen.
    func testControlCharactersInAReplyAreReplaced() {
        let reply = RefreshSignal.reply(from: [
            "state": "failed", "message": "denied\u{1B}[2J\rok"])
        // CR ends the line rather than returning over it.
        XCTAssertEqual(reply, .failed("denied\u{FFFD}[2J\nok"))
        let notes = RefreshSignal.reply(from: [
            "state": "finished", "notes": "EC2: no\u{7}\nSSM: fine"])
        XCTAssertEqual(notes, .finished(notes: ["EC2: no\u{FFFD}", "SSM: fine"]))
    }

    func testAnOverlongReplyIsCut() {
        let reply = RefreshSignal.reply(from: [
            "state": "failed", "message": String(repeating: "x", count: 50_000)])
        guard case .failed(let message) = reply else { return XCTFail("\(String(describing: reply))") }
        XCTAssertEqual(message.count, RefreshSignal.longestMessage)
    }

    /// U+009B is CSI in one scalar, which some terminals obey.
    func testC1ControlsInAReplyAreReplaced() {
        XCTAssertEqual(RefreshSignal.reply(from: ["state": "failed", "message": "a\u{9B}2Jb"]),
                       .failed("a\u{FFFD}2Jb"))
    }

    /// Combining marks are many scalars in one character, so a cap counted in
    /// characters let a forged reply through at any size.
    func testTheCapCountsScalars() {
        let flood = "e" + String(repeating: "\u{301}", count: 50_000)
        let reply = RefreshSignal.reply(from: ["state": "failed", "message": flood])
        guard case .failed(let message) = reply else { return XCTFail("\(String(describing: reply))") }
        XCTAssertEqual(message.unicodeScalars.count, RefreshSignal.longestMessage)
    }

    // MARK: - When a request fetches

    let now = Date(timeIntervalSince1970: 2_000_000)
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testAStaleFleetIsFetched() {
        XCTAssertTrue(RefreshSignal.shouldFetch(fetchedAt: ago(600), lastFailed: false,
                                                lastRequested: nil, now: now))
        XCTAssertTrue(RefreshSignal.shouldFetch(fetchedAt: nil, lastFailed: false,
                                                lastRequested: nil, now: now))
    }

    func testARefreshThatJustSucceededAnswersTheRequest() {
        XCTAssertFalse(RefreshSignal.shouldFetch(fetchedAt: ago(2), lastFailed: false,
                                                 lastRequested: nil, now: now))
        XCTAssertTrue(RefreshSignal.shouldFetch(
            fetchedAt: ago(RefreshSignal.reuseWithin), lastFailed: false,
            lastRequested: nil, now: now))
    }

    func testAFailureIsRetried() {
        XCTAssertTrue(RefreshSignal.shouldFetch(fetchedAt: ago(2), lastFailed: true,
                                                lastRequested: nil, now: now))
    }

    /// A loop of requests against a refresh that keeps failing would otherwise
    /// resolve credentials back to back, and a credential_process may prompt.
    func testRequestsAreSpacedEvenAfterAFailure() {
        XCTAssertFalse(RefreshSignal.shouldFetch(fetchedAt: ago(600), lastFailed: true,
                                                 lastRequested: ago(3), now: now))
        XCTAssertTrue(RefreshSignal.shouldFetch(
            fetchedAt: ago(600), lastFailed: true,
            lastRequested: ago(RefreshSignal.reuseWithin), now: now))
    }

    /// A clock that moved backwards is neither a fresh fleet nor a recent request.
    func testAFutureDateIsNotRecent() {
        XCTAssertTrue(RefreshSignal.shouldFetch(fetchedAt: now.addingTimeInterval(60),
                                                lastFailed: false,
                                                lastRequested: now.addingTimeInterval(60),
                                                now: now))
    }
}

final class RefreshWaitTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testNothingYetIsWaiting() {
        let wait = RefreshWait(startedAt: start, finishWithin: 120)
        XCTAssertEqual(wait.outcome(at: at(1)), .waiting)
    }

    func testSilenceMeansNoAppIsRunning() {
        let wait = RefreshWait(startedAt: start, finishWithin: 120)
        XCTAssertEqual(wait.outcome(at: at(RefreshWait.answerWithin)), .noAnswer)
    }

    func testAnAnsweredRequestWaitsForTheRefresh() {
        var wait = RefreshWait(startedAt: start, finishWithin: 120)
        wait.receive(.started)
        XCTAssertEqual(wait.outcome(at: at(60)), .waiting)
        XCTAssertEqual(wait.outcome(at: at(120)), .timedOut)
    }

    func testFinishingEndsTheWait() {
        var wait = RefreshWait(startedAt: start, finishWithin: 120)
        wait.receive(.started)
        wait.receive(.finished(notes: ["SSM: denied"]))
        XCTAssertEqual(wait.outcome(at: at(5)), .refreshed(notes: ["SSM: denied"]))
    }

    func testAFailureEndsTheWait() {
        var wait = RefreshWait(startedAt: start, finishWithin: 120)
        wait.receive(.started)
        wait.receive(.failed("expired"))
        XCTAssertEqual(wait.outcome(at: at(5)), .failed("expired"))
    }

    /// The started reply can be overtaken, and a result with no start is still
    /// a result rather than silence.
    func testAResultWithoutAStartStillCounts() {
        var wait = RefreshWait(startedAt: start, finishWithin: 120)
        wait.receive(.finished(notes: []))
        XCTAssertEqual(wait.outcome(at: at(10)), .refreshed(notes: []))
    }

    /// Two copies of the app can both answer. The first result is the one kept.
    func testTheFirstResultWins() {
        var wait = RefreshWait(startedAt: start, finishWithin: 120)
        wait.receive(.failed("expired"))
        wait.receive(.finished(notes: []))
        XCTAssertEqual(wait.outcome(at: at(10)), .failed("expired"))
    }

    func testATimeoutShorterThanTheAnswerWindowIsHonored() {
        let wait = RefreshWait(startedAt: start, finishWithin: 1)
        XCTAssertEqual(wait.outcome(at: at(1)), .noAnswer)
    }
}
