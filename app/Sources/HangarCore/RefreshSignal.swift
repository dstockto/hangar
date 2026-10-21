import Foundation

/// How `hangar refresh` asks the running app to refresh the fleet, and how the
/// app answers.
///
/// The command line never calls AWS itself, so a refresh from the shell is a
/// request to the app over a distributed notification. Any process in the login
/// session can post one, so everything that arrives here is treated as untrusted.
public enum RefreshSignal {
    /// Posted by the command line, with the request id as the object.
    public static let request = "com.goriparthi.hangar.refresh.request"
    /// Posted by the app, with the same id as the object.
    public static let reply = "com.goriparthi.hangar.refresh.reply"

    /// The shortest gap between fetches started by requests. A refresh that
    /// succeeded this recently answers without fetching, so a script asking once
    /// per host costs one fetch. A failed one does not, but a request still may
    /// not start another this soon, because each fetch resolves credentials and
    /// a `credential_process` may prompt.
    public static let reuseWithin: TimeInterval = 10

    /// Requests held while one refresh is answered. Past this they are dropped:
    /// any process in the session can post, and each held request is a reply.
    public static let mostWaiting = 64

    /// The longest failure text the command line will print. The app's own
    /// advice runs to a few hundred characters; anything longer did not come
    /// from it.
    static let longestMessage = 2000

    public enum Reply: Equatable, Sendable {
        /// The app has the request. Says the app is running.
        case started
        /// The refresh finished and the cache was written. Each note is a source
        /// that failed while others succeeded, already worded for a person.
        case finished(notes: [String])
        /// Nothing was fetched from any source; the cache is as it was.
        case failed(String)
    }

    /// The id is echoed back by the app, so it is held to the one shape the
    /// command line generates rather than passed through as given.
    public static func isRequestID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    public static func userInfo(for reply: Reply) -> [String: String] {
        switch reply {
        case .started:
            return ["state": "started"]
        case .finished(let notes):
            var info = ["state": "finished"]
            if !notes.isEmpty { info["notes"] = notes.joined(separator: "\n") }
            return info
        case .failed(let message):
            return ["state": "failed", "message": message]
        }
    }

    /// The reply in a notification, or nil when it is not one this version
    /// recognizes. Text is made safe to print here, once, so no caller has to
    /// remember to.
    public static func reply(from userInfo: [AnyHashable: Any]?) -> Reply? {
        guard let state = userInfo?["state"] as? String else { return nil }
        switch state {
        case "started":
            return .started
        case "finished":
            let notes = (userInfo?["notes"] as? String).map(lines) ?? []
            return .finished(notes: notes)
        case "failed":
            let message = (userInfo?["message"] as? String).map(lines) ?? []
            return .failed(message.isEmpty ? "the refresh failed" : message.joined(separator: "\n"))
        default:
            return nil
        }
    }

    /// Non-empty lines with control characters replaced, so a reply cannot move
    /// the cursor or forge a line the app did not send. Capped in scalars, not
    /// characters: one character can carry any number of combining marks.
    static func lines(_ text: String) -> [String] {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(longestMessage)))
            .split(whereSeparator: \.isNewline)
            .map { FleetOutput.display(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether a request may start a fetch, or must be answered with what the
    /// app already has. `lastRequested` is when a request last started one.
    public static func shouldFetch(fetchedAt: Date?, lastFailed: Bool,
                                   lastRequested: Date?, now: Date) -> Bool {
        func recent(_ date: Date?) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < reuseWithin
        }
        if recent(lastRequested) { return false }
        return lastFailed || !recent(fetchedAt)
    }
}

/// What the command line knows while it waits for an answer.
///
/// Kept apart from the waiting itself so the timing is testable: the process
/// runs the loop, and this decides when the loop is done and what it means.
public struct RefreshWait: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case refreshed(notes: [String])
        case failed(String)
        /// Nothing answered, so no app is running to ask.
        case noAnswer
        /// The app answered and did not finish in time.
        case timedOut
    }

    /// How long a running app gets to say it has the request. The app answers
    /// before it starts work, so this is short.
    public static let answerWithin: TimeInterval = 3

    public let startedAt: Date
    public let finishWithin: TimeInterval
    private var answered = false
    private var result: Outcome?

    public init(startedAt: Date, finishWithin: TimeInterval) {
        self.startedAt = startedAt
        self.finishWithin = finishWithin
    }

    public mutating func receive(_ reply: RefreshSignal.Reply) {
        answered = true
        guard result == nil else { return }
        switch reply {
        case .started:                 break
        case .finished(let notes):     result = .refreshed(notes: notes)
        case .failed(let message):     result = .failed(message)
        }
    }

    public func outcome(at now: Date) -> Outcome {
        if let result { return result }
        let elapsed = now.timeIntervalSince(startedAt)
        if !answered, elapsed >= min(RefreshWait.answerWithin, finishWithin) {
            return .noAnswer
        }
        return elapsed >= finishWithin ? .timedOut : .waiting
    }
}
