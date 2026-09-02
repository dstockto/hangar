import Foundation
import os

/// Hangar's log, in two places at once.
///
/// `os.Logger` because it is free, structured, survives a crash and shows up in
/// Console.app; a file because `log show` needs the CLI and a predicate, its
/// retention is not ours to control, and anyone debugging a running Hangar,
/// person or agent, should be able to tail a path.
///
/// Nothing sensitive reaches either sink: credentials are never passed in, and
/// hostnames and instance ids are put through `Redact` at the call site. A
/// logger that tries to guess which of its fields are sensitive guesses wrong.
public enum Log {
    public enum Category: String, Sendable, CaseIterable {
        case app, fleet, credentials, ssh, updates, uninstall
    }

    public enum Level: String, Sendable, Comparable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }

        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }

        var osLevel: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    /// Debug goes to the unified log only. The file is events and errors, so it
    /// stays short enough to read and to attach.
    public static let fileThreshold: Level = .info

    public static func debug(_ category: Category, _ message: String,
                             _ fields: [String: String] = [:]) {
        emit(.debug, category, message, fields)
    }

    public static func info(_ category: Category, _ message: String,
                            _ fields: [String: String] = [:]) {
        emit(.info, category, message, fields)
    }

    public static func warning(_ category: Category, _ message: String,
                               _ fields: [String: String] = [:]) {
        emit(.warning, category, message, fields)
    }

    public static func error(_ category: Category, _ message: String,
                             _ fields: [String: String] = [:]) {
        emit(.error, category, message, fields)
    }

    // MARK: - Rendering

    /// `2026-09-02T13:41:09Z  INFO   fleet        refresh finished  hosts=223`
    ///
    /// UTC always. Level and category are padded so a screenful lines up, and
    /// fields are sorted by key so two runs can be diffed against each other.
    static func line(_ level: Level, _ category: Category, _ message: String,
                     _ fields: [String: String], at date: Date) -> String {
        var text = "\(timestamp(date))  \(pad(level.rawValue, 5))  "
            + "\(pad(category.rawValue, 11))  \(message)"
        if !fields.isEmpty {
            let rendered = fields.keys.sorted().map { key in
                "\(key)=\(quoteIfNeeded(fields[key] ?? ""))"
            }
            text += "  " + rendered.joined(separator: " ")
        }
        return text
    }

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value
            : value + String(repeating: " ", count: width - value.count)
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuotes = value.isEmpty
            || value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || value.contains("\"")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    // MARK: - Sinks

    private static let subsystem =
        Bundle.main.bundleIdentifier ?? "com.goriparthi.hangar"

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// The file sink is off under XCTest. A test run writing into the user's real
    /// log pollutes the thing they are meant to read and makes the suite depend
    /// on a home directory; `LogFile` is exercised directly instead.
    private static let fileSinkEnabled: Bool = NSClassFromString("XCTest") == nil

    private static func emit(_ level: Level, _ category: Category,
                             _ message: String, _ fields: [String: String]) {
        let text = line(level, category, message, fields, at: Date())
        // Public because redaction already happened at the call site; marking a
        // pre-redacted string private would only hide it from the person
        // debugging their own machine.
        logger(for: category).log(level: level.osLevel, "\(text, privacy: .public)")
        guard fileSinkEnabled, level >= fileThreshold else { return }
        _ = pump
        pipe.continuation.yield(text)
    }

    /// One consumer behind a stream, rather than a task per line: an actor
    /// serializes the writes but not the order they arrive in, and a log whose
    /// lines can swap places is a log that misleads.
    private static let pipe: (stream: AsyncStream<String>,
                              continuation: AsyncStream<String>.Continuation) = {
        var escaped: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(512)) {
            escaped = $0
        }
        return (stream, escaped)
    }()

    private static let pump: Task<Void, Never> = Task.detached(priority: .utility) {
        for await text in pipe.stream { await LogFile.shared.append(text) }
    }
}

/// The file sink. An actor because this module is Swift 6 with no
/// `@unchecked Sendable` waivers, and a shared file handle needs serializing.
actor LogFile {
    static let shared = LogFile()

    private let path: String
    private let rotateAt: Int

    init(path: String = HangarConfig.logPath, rotateAt: Int = 512 * 1024) {
        self.path = path
        self.rotateAt = rotateAt
    }

    func append(_ text: String) {
        let data = Data((text + "\n").utf8)
        let fm = FileManager.default
        PrivateFile.ensureDirectory((path as NSString).deletingLastPathComponent)
        rotateIfNeeded(adding: data.count)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        // A log that throws, or that stops the app to complain about its own
        // disk, is worse than a missing line.
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// One generation kept, so the log costs about a megabyte at worst and never
    /// needs pruning by hand.
    private func rotateIfNeeded(adding bytes: Int) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size + bytes > rotateAt else { return }
        let previous = path + ".1"
        try? fm.removeItem(atPath: previous)
        try? fm.moveItem(atPath: path, toPath: previous)
    }
}
