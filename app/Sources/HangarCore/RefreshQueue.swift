import Foundation

/// The app's side of `hangar refresh`: which requests are held, whether one
/// starts a fetch, and what they are all told once the refresh lands.
///
/// Kept out of the listener so the batching is testable. The listener only
/// watches the store and posts what this decides.
public struct RefreshQueue: Equatable, Sendable {
    /// What happens to a request that just arrived.
    public enum Admission: Equatable, Sendable {
        /// Too many are held already. It gets no reply, not even `.started`.
        case dropped
        /// Held, and first in line: the caller starts the answer.
        case startsAnswer
        /// Held behind an answer already under way, which answers this one too.
        case joined
    }

    /// Requests waiting on the answer. One refresh answers all of them, so a
    /// flood of requests is one task, not one each.
    private(set) var waiting: [String] = []
    /// When a request last started a fetch, whatever the fetch then did.
    private(set) var lastRequested: Date?

    public init() {}

    /// Holds the request unless the cap is reached. Each held request is a reply
    /// owed, and any process in the session can post one.
    public mutating func admit(_ id: String) -> Admission {
        guard waiting.count < RefreshSignal.mostWaiting else { return .dropped }
        waiting.append(id)
        return waiting.count == 1 ? .startsAnswer : .joined
    }

    /// Whether answering starts a fetch. A refresh already running is joined
    /// instead, and a fetch started here is recorded so the next one is spaced.
    public mutating func startsFetch(isRefreshing: Bool, fetchedAt: Date?,
                                     lastFailed: Bool, now: Date) -> Bool {
        guard !isRefreshing,
              RefreshSignal.shouldFetch(fetchedAt: fetchedAt, lastFailed: lastFailed,
                                        lastRequested: lastRequested, now: now)
        else { return false }
        lastRequested = now
        return true
    }

    /// Every held request, released together, so the next one to arrive starts
    /// a new answer rather than joining one that has already been sent.
    public mutating func release() -> [String] {
        defer { waiting = [] }
        return waiting
    }

    /// What a landed refresh tells the command line. A source that failed while
    /// others worked is a note on success, named so the user knows which one.
    public static func reply(failure: String?, reports: [SourceReport]) -> RefreshSignal.Reply {
        if let failure { return .failed(failure) }
        return .finished(notes: reports.compactMap { report in
            report.problem.map { "\(report.source.label): \($0)" }
        })
    }
}
