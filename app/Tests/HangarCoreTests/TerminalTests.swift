import XCTest
@testable import HangarCore

/// What the other end of stdout is, and what may be written to it.
final class TerminalTests: XCTestCase {

    private func terminal(tty: Bool, env: [String: String] = [:]) -> Terminal {
        Terminal.standardOutput(isatty: { _ in tty }, environment: env)
    }

    func testAPipeIsNotInteractive() {
        let pipe = terminal(tty: false)
        XCTAssertFalse(pipe.isInteractive)
        XCTAssertFalse(pipe.isColoured)
    }

    func testATerminalIsInteractiveAndColoured() {
        let tty = terminal(tty: true)
        XCTAssertTrue(tty.isInteractive)
        XCTAssertTrue(tty.isColoured)
    }

    /// no-color.org specifies "present and not an empty string (regardless of its
    /// value)". Empty is the documented way to undo it for one command, so
    /// `NO_COLOR= hangar` has to keep colour.
    func testNoColorIsHonouredWhenPresentAndNotEmpty() {
        XCTAssertFalse(terminal(tty: true, env: ["NO_COLOR": "1"]).isColoured)
        XCTAssertFalse(terminal(tty: true, env: ["NO_COLOR": "0"]).isColoured)
        XCTAssertTrue(terminal(tty: true, env: ["NO_COLOR": ""]).isColoured)
        // Still a terminal: headings and layout are not colour.
        XCTAssertTrue(terminal(tty: true, env: ["NO_COLOR": "1"]).isInteractive)
    }

    func testHangarNoColorFollowsTheSameRule() {
        XCTAssertFalse(terminal(tty: true, env: ["HANGAR_NO_COLOR": "1"]).isColoured)
        XCTAssertTrue(terminal(tty: true, env: ["HANGAR_NO_COLOR": ""]).isColoured)
    }

    func testADumbTerminalGetsNoSequences() {
        XCTAssertFalse(terminal(tty: true, env: ["TERM": "dumb"]).isColoured)
        XCTAssertTrue(terminal(tty: true, env: ["TERM": "xterm-256color"]).isColoured)
    }

    /// A pipe is never coloured, whatever the environment says, because the
    /// escape sequences would reach whatever is parsing it.
    func testColourIsNeverOnForAPipe() {
        XCTAssertFalse(terminal(tty: false, env: ["TERM": "xterm-256color"]).isColoured)
        XCTAssertFalse(Terminal(isInteractive: false, isColoured: true).isColoured)
    }

    func testPlainIsWhatAPipeGets() {
        XCTAssertFalse(Terminal.plain.isInteractive)
        XCTAssertFalse(Terminal.plain.isColoured)
    }

    // MARK: - Sequences

    func testStyledWrapsOnlyWhenColoured() {
        let tty = Terminal(isInteractive: true, isColoured: true)
        XCTAssertEqual(tty.styled("web", .heading), "\u{1B}[1mweb\u{1B}[0m")
        XCTAssertEqual(Terminal.plain.styled("web", .heading), "web")
    }

    func testStyledLeavesEmptyTextAlone() {
        let tty = Terminal(isInteractive: true, isColoured: true)
        XCTAssertEqual(tty.styled("", .heading), "")
    }

    func testEveryStyleResetsItself() {
        let tty = Terminal(isInteractive: true, isColoured: true)
        for style in [Terminal.Style.heading, .secondary, .dimmed] {
            XCTAssertTrue(tty.styled("x", style).hasSuffix("\u{1B}[0m"))
        }
    }
}

/// stderr, which is where a chooser writes. stdout may be a pipe while a person
/// is still sitting there to answer.
final class StandardErrorTerminalTests: XCTestCase {

    private func stderrTerminal(fd2: Bool, env: [String: String] = [:]) -> Terminal {
        Terminal.standardError(isatty: { $0 == 2 ? fd2 : false }, environment: env)
    }

    func testItAsksAboutDescriptorTwo() {
        XCTAssertTrue(stderrTerminal(fd2: true).isInteractive)
        XCTAssertFalse(stderrTerminal(fd2: false).isInteractive)
    }

    func testItHonoursTheSameColourSuppression() {
        XCTAssertFalse(stderrTerminal(fd2: true, env: ["NO_COLOR": "1"]).isColoured)
        XCTAssertTrue(stderrTerminal(fd2: true, env: ["NO_COLOR": ""]).isColoured)
    }
}
