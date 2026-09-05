import Foundation

/// One `-f key=value` clause from the command line.
///
/// The dictionary the hotkeys use cannot express what people actually ask for.
/// It is one value per key, so "prod or staging" needs two filters that would
/// overwrite each other, and it has no way to say "not the canaries" at all.
///
/// Deliberately not applied to `~/.hangar/config.json`: hotkey filters keep the
/// dictionary form and the dictionary meaning, because a config file written
/// against the old rules must not start meaning something else after an update.
public struct HostFilter: Equatable, Sendable {
    public enum Match: Equatable, Sendable {
        /// `key=value`. True when any pattern matches.
        case any
        /// `key!=value`. True when none of them do.
        case none
    }

    public var key: String
    /// Patterns, already unescaped. Any one matching is a hit.
    public var patterns: [String]
    public var match: Match

    public init(key: String, patterns: [String], match: Match = .any) {
        self.key = key
        self.patterns = patterns
        self.match = match
    }

    /// A clause, or the wording the command line reports. A `String` rather than
    /// a thrown error because that is what `HangarCommand` carries: one place
    /// decides how a bad command line reads.
    public enum Parsed: Equatable, Sendable {
        case filter(HostFilter)
        case problem(String)
    }

    /// Parses `key=a,b`, `key!=a`, and a `\,` that means a comma rather than a
    /// separator.
    public static func parse(_ text: String) -> Parsed {
        let (rawKey, rawValue, match) = split(text)
        guard let rawKey, let rawValue, !rawKey.isEmpty else {
            return .problem("--filter takes key=value or key!=value, not '\(text)'")
        }
        let alternatives = patterns(in: rawValue)
        // An empty alternative is the wildcard, so one stray comma quietly makes
        // the clause true for every host and the values either side of it say
        // nothing. Reported rather than guessed at, because there is no reading
        // of it that means something else: an empty pattern cannot mean "hosts
        // with no value here", it already means "any value at all".
        if !rawValue.isEmpty, alternatives.contains(where: \.isEmpty) {
            return .problem("--filter has an empty value in '\(text)', which "
                            + "would match every host. Use \\, for a comma in a value.")
        }
        return .filter(HostFilter(key: rawKey, patterns: alternatives, match: match))
    }

    /// Splits on the first `!=` or `=`, whichever comes first, so a value may
    /// contain either.
    private static func split(_ text: String) -> (String?, String?, Match) {
        guard let equals = text.firstIndex(of: "=") else { return (nil, nil, .any) }
        let negated = equals > text.startIndex
            && text[text.index(before: equals)] == "!"
        let keyEnd = negated ? text.index(before: equals) : equals
        return (String(text[text.startIndex..<keyEnd]),
                String(text[text.index(after: equals)...]),
                negated ? .none : .any)
    }

    /// Comma separates alternatives. A backslash before one means the comma is
    /// part of the value, because a tag nobody can name is a tag nobody can
    /// filter on.
    private static func patterns(in value: String) -> [String] {
        var found: [String] = []
        var current = ""
        var escaping = false
        for character in value {
            if escaping {
                // Only a comma is escapable, so every other backslash survives as
                // itself rather than disappearing out of a pattern.
                if character != "," { current.append("\\") }
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "," {
                found.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaping { current.append("\\") }
        found.append(current)
        return found
    }

    /// Whether one host satisfies this clause. `tagValue(for:)` is what resolves
    /// the friendly names, so `name`, `state` and `id` work alongside real tags.
    public func matches(_ instance: Instance) -> Bool {
        let value = instance.tagValue(for: key)
        let hit = patterns.contains { HangarConfig.wildcard($0, value) }
        return match == .any ? hit : !hit
    }
}
