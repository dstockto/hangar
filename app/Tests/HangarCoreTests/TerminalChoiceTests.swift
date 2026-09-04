import XCTest
@testable import HangarCore

/// `terminal` in ~/.hangar/config.json is hand-edited, and the argument vector
/// is what reaches a terminal that takes a command rather than an AppleScript.
final class TerminalChoiceTests: XCTestCase {

    func testItReadsTheSpellingsAHandEditedConfigWillHave() {
        XCTAssertEqual(TerminalChoice.from("ghostty"), .ghostty)
        XCTAssertEqual(TerminalChoice.from("Ghostty.app"), .ghostty)
        XCTAssertEqual(TerminalChoice.from("com.mitchellh.ghostty"), .ghostty)
        XCTAssertEqual(TerminalChoice.from("Terminal"), .terminal)
        XCTAssertEqual(TerminalChoice.from(" terminal.app "), .terminal)
        XCTAssertEqual(TerminalChoice.from("iterm"), .iterm)
        XCTAssertEqual(TerminalChoice.from("iTerm2"), .iterm)
    }

    /// An unreadable value keeps today's behaviour rather than silently changing
    /// which app opens on the next launch.
    func testAnUnknownValueStaysOnTheDefault() {
        XCTAssertEqual(TerminalChoice.from(nil), .iterm)
        XCTAssertEqual(TerminalChoice.from(""), .iterm)
        XCTAssertEqual(TerminalChoice.from("kitty"), .iterm)
    }

    func testTheConfigValueRoundTrips() {
        for choice in TerminalChoice.allCases {
            XCTAssertEqual(TerminalChoice.from(choice.rawValue), choice)
        }
    }

    /// Capitalisation is part of a name; mistake 8 was uppercasing one.
    func testNamesKeepTheirCapitalisation() {
        XCTAssertEqual(TerminalChoice.iterm.displayName, "iTerm2")
        XCTAssertEqual(TerminalChoice.ghostty.displayName, "Ghostty")
        XCTAssertEqual(TerminalChoice.terminal.displayName, "Terminal")
    }

    /// Only the scripted ones need permission under Automation, and the setup
    /// check says so, so this has to be right rather than incidental.
    func testOnlyTheScriptableTerminalsAreScripted() {
        XCTAssertEqual(TerminalChoice.iterm.mechanism, .appleScript)
        XCTAssertEqual(TerminalChoice.terminal.mechanism, .appleScript)
        XCTAssertEqual(TerminalChoice.ghostty.mechanism, .arguments)
    }

    /// The fallback has to be the one that cannot be missing.
    func testTheFallbackShipsWithMacOS() {
        XCTAssertEqual(TerminalChoice.fallback, .terminal)
    }

    /// The command is one element of the vector, so nothing re-parses it and a
    /// quoted alias survives.
    func testTheCommandIsOneArgumentRatherThanAReparsedString() {
        let arguments = TerminalChoice.arguments(for: "ssh 'web 1'")
        XCTAssertEqual(arguments[0], "-e")
        XCTAssertEqual(arguments[1], "/bin/sh")
        XCTAssertEqual(arguments[2], "-c")
        XCTAssertEqual(arguments.count, 4)
        XCTAssertTrue(arguments[3].hasPrefix("ssh 'web 1';"), arguments[3])
    }

    /// A window that closes the moment ssh fails teaches nobody why, which is
    /// the reason the scripted terminals write into a live session.
    func testTheSessionOutlivesAFailedSSH() {
        let command = TerminalChoice.arguments(for: "ssh nope").last ?? ""
        XCTAssertTrue(command.contains("exec \"${SHELL:-/bin/sh}\" -l"), command)
    }
}
