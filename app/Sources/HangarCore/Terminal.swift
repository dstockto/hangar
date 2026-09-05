import Foundation

/// What the other end of stdout is.
///
/// The `hangar` command has two readers and until now only served one. A pipe
/// wants the same bytes every time, and a person wants headings, state and some
/// colour. Deciding between them is one `isatty` call, and putting it here keeps
/// the decision testable rather than buried in a formatter.
public struct Terminal: Equatable, Sendable {
    /// Whether the destination is a terminal rather than a pipe or a file.
    public var isInteractive: Bool
    /// Whether escape sequences may be written. Never true when the destination
    /// is not interactive.
    public var isColoured: Bool

    /// Colour is stored as asked *and* interactive, never as given: escape
    /// sequences written to a pipe reach whatever is parsing it, so there is no
    /// state where a caller gets colour without a terminal to spend it on.
    public init(isInteractive: Bool, isColoured: Bool) {
        self.isInteractive = isInteractive
        self.isColoured = isColoured && isInteractive
    }

    /// A pipe, a file, or anything else being read by a program. What every
    /// version so far produced, for everyone.
    public static let plain = Terminal(isInteractive: false, isColoured: false)

    /// Reads the real file descriptor and the environment around it.
    ///
    /// `NO_COLOR` is honoured when it is present *and not empty*, which is what
    /// no-color.org actually specifies: "present and not an empty string
    /// (regardless of its value)". So `NO_COLOR= hangar` leaves colour on, which
    /// is the documented way to undo it for one command. `TERM=dumb` is a
    /// terminal that has said it cannot do this.
    public static func standardOutput(
        isatty: (Int32) -> Bool = { Foundation.isatty($0) == 1 },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Terminal {
        let interactive = isatty(1)
        let set = { (name: String) in environment[name].map { !$0.isEmpty } ?? false }
        let suppressed = set("NO_COLOR") || set("HANGAR_NO_COLOR")
            || environment["TERM"] == "dumb"
        return Terminal(isInteractive: interactive, isColoured: !suppressed)
    }

    /// The same question about stderr, which is where a chooser has to write:
    /// stdout may be a pipe even while a person is sitting there to answer.
    public static func standardError(
        isatty: (Int32) -> Bool = { Foundation.isatty($0) == 1 },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Terminal {
        standardOutput(isatty: { _ in isatty(2) }, environment: environment)
    }

    // MARK: - Sequences

    /// Wraps text in an SGR sequence, or returns it untouched when colour is off.
    ///
    /// Colour is never the only thing saying something here. A stopped host says
    /// "stopped" in words as well, because a reader who cannot see the dimming,
    /// or is reading a copied and pasted line, has to get the same answer.
    public func styled(_ text: String, _ style: Style) -> String {
        guard isColoured, !text.isEmpty else { return text }
        return "\u{1B}[\(style.code)m\(text)\u{1B}[0m"
    }

    public enum Style: Sendable {
        /// A group heading.
        case heading
        /// Present but not the point: a hostname beside the alias you will type.
        case secondary
        /// A host that is not running.
        case dimmed

        var code: String {
            switch self {
            case .heading:   return "1"     // bold
            case .secondary: return "2"     // faint
            case .dimmed:    return "2"
            }
        }
    }
}
