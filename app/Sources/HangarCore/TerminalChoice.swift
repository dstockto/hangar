import Foundation

/// The terminal Hangar hands a session to.
///
/// UI-free so the mapping, the display names and the argument vector are
/// testable: `terminal` in `~/.hangar/config.json` is hand-edited, and the
/// argument vector is what reaches a terminal that takes a command rather than
/// an AppleScript.
public enum TerminalChoice: String, Sendable, Equatable, CaseIterable {
    case iterm, terminal, ghostty

    /// Capitalisation is part of a name. Mistake 8 was uppercasing one.
    public var displayName: String {
        switch self {
        case .iterm:    return "iTerm2"
        case .terminal: return "Terminal"
        case .ghostty:  return "Ghostty"
        }
    }

    public var bundleID: String {
        switch self {
        case .iterm:    return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        case .ghostty:  return "com.mitchellh.ghostty"
        }
    }

    /// How a session gets started. Two terminals here are scriptable and one is
    /// not, and that difference decides more than the launch: only the scripted
    /// ones need permission under Privacy and Security, Automation.
    public enum Mechanism: Sendable, Equatable {
        /// Written into a live session with AppleScript.
        case appleScript
        /// Launched with the command in its argument vector.
        case arguments
    }

    public var mechanism: Mechanism {
        switch self {
        case .iterm, .terminal: return .appleScript
        case .ghostty:          return .arguments
        }
    }

    /// The one Hangar falls back to when the chosen terminal is not installed.
    /// Terminal ships with macOS, so this is the only choice that cannot fail.
    public static let fallback: TerminalChoice = .terminal

    /// Reads the config value, tolerantly. The file is hand-edited, so "iTerm",
    /// "iterm2" and "Terminal.app" all have to land somewhere sensible, and an
    /// unreadable value keeps today's behaviour rather than silently changing
    /// which app opens.
    public static func from(_ raw: String?) -> TerminalChoice {
        switch (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "terminal", "terminal.app", "apple", "com.apple.terminal":
            return .terminal
        case "ghostty", "ghostty.app", "com.mitchellh.ghostty":
            return .ghostty
        default:
            return .iterm
        }
    }

    /// The argument vector for a terminal that takes a command.
    ///
    /// The command runs under `/bin/sh` and hands over to a login shell
    /// afterwards, so a failing ssh leaves its error on screen. Passed as the
    /// command's own argument rather than a terminal that exits on failure,
    /// because a window that closes on error teaches nobody why.
    public static func arguments(for command: String) -> [String] {
        ["-e", "/bin/sh", "-c", command + "; exec \"${SHELL:-/bin/sh}\" -l"]
    }
}
