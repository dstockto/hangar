import XCTest
@testable import HangarCore

/// The `hangar` command line. Every one of these was previously unreachable:
/// the parser lived in an executable target.
final class HangarCommandTests: XCTestCase {

    func testNoArgumentsListsEverything() {
        let command = HangarCommand.parse([])
        XCTAssertTrue(command.query.isEmpty)
        XCTAssertEqual(command.format, .columns)
        XCTAssertNil(command.limit)
        XCTAssertTrue(command.filters.isEmpty)
        XCTAssertNil(command.problem)
    }

    func testBareWordsAreTheQuery() {
        let command = HangarCommand.parse(["web", "prod"])
        XCTAssertEqual(command.query, ["web", "prod"])
        XCTAssertEqual(command.searchText, "web prod")
        XCTAssertNil(command.problem)
    }

    func testSearchFlagAppendsToTheQuery() {
        XCTAssertEqual(HangarCommand.parse(["-s", "web prod"]).searchText, "web prod")
        XCTAssertEqual(HangarCommand.parse(["--search", "db"]).searchText, "db")
        // Spelled out and bare are the same query, in the order given.
        XCTAssertEqual(HangarCommand.parse(["-s", "web", "prod"]).searchText, "web prod")
    }

    func testFormatFlags() {
        XCTAssertEqual(HangarCommand.parse(["-a"]).format, .alias)
        XCTAssertEqual(HangarCommand.parse(["--alias"]).format, .alias)
        XCTAssertEqual(HangarCommand.parse(["--aliases"]).format, .alias)
        XCTAssertEqual(HangarCommand.parse(["--tsv"]).format, .tsv)
        XCTAssertEqual(HangarCommand.parse(["--json"]).format, .json)
    }

    func testListFlagIsTheDefault() {
        XCTAssertEqual(HangarCommand.parse(["-l"]), HangarCommand.parse([]))
        XCTAssertEqual(HangarCommand.parse(["--list"]), HangarCommand.parse([]))
    }

    func testLimitTakesAPositiveNumber() {
        XCTAssertEqual(HangarCommand.parse(["-n", "5"]).limit, 5)
        XCTAssertEqual(HangarCommand.parse(["--limit", "5"]).limit, 5)
    }

    func testLimitRejectsAnythingElse() {
        XCTAssertEqual(HangarCommand.parse(["-n", "0"]).problem,
                       "--limit needs a positive number, not '0'")
        XCTAssertEqual(HangarCommand.parse(["-n", "-3"]).problem,
                       "--limit needs a positive number, not '-3'")
        XCTAssertEqual(HangarCommand.parse(["-n", "lots"]).problem,
                       "--limit needs a positive number, not 'lots'")
    }

    func testFilterTakesKeyEqualsValue() {
        XCTAssertEqual(HangarCommand.parse(["-f", "env=prod"]).filters, ["env": "prod"])
        // The value may contain an equals sign; only the first splits.
        XCTAssertEqual(HangarCommand.parse(["-f", "tag=a=b"]).filters, ["tag": "a=b"])
    }

    func testFilterRejectsAnythingElse() {
        XCTAssertEqual(HangarCommand.parse(["-f", "env"]).problem,
                       "--filter takes key=value, not 'env'")
        XCTAssertEqual(HangarCommand.parse(["-f", "=prod"]).problem,
                       "--filter takes key=value, not '=prod'")
    }

    func testAFlagMissingItsValueIsReported() {
        XCTAssertEqual(HangarCommand.parse(["-s"]).problem, "-s needs a value")
        XCTAssertEqual(HangarCommand.parse(["-n"]).problem, "-n needs a value")
        XCTAssertEqual(HangarCommand.parse(["-f"]).problem, "-f needs a value")
        XCTAssertEqual(HangarCommand.parse(["--cache"]).problem, "--cache needs a value")
    }

    func testUnknownOptionIsReportedRatherThanSearchedFor() {
        XCTAssertEqual(HangarCommand.parse(["--wat"]).problem, "unknown option '--wat'")
        XCTAssertTrue(HangarCommand.parse(["--wat"]).query.isEmpty)
    }

    /// A single hyphen is a conventional argument, not a mistyped flag.
    func testLoneHyphenIsQuery() {
        let command = HangarCommand.parse(["-"])
        XCTAssertEqual(command.query, ["-"])
        XCTAssertNil(command.problem)
    }

    func testHelpAndVersion() {
        XCTAssertTrue(HangarCommand.parse(["-h"]).help)
        XCTAssertTrue(HangarCommand.parse(["--help"]).help)
        XCTAssertTrue(HangarCommand.parse(["-V"]).version)
        XCTAssertTrue(HangarCommand.parse(["--version"]).version)
    }

    func testCachePath() {
        XCTAssertEqual(HangarCommand.parse(["--cache", "/tmp/fleet"]).cache, "/tmp/fleet")
    }

    func testEverythingAtOnce() {
        let command = HangarCommand.parse(
            ["--json", "-f", "env=prod", "-n", "3", "web", "--cache", "/tmp/c"])
        XCTAssertEqual(command.format, .json)
        XCTAssertEqual(command.filters, ["env": "prod"])
        XCTAssertEqual(command.limit, 3)
        XCTAssertEqual(command.searchText, "web")
        XCTAssertEqual(command.cache, "/tmp/c")
        XCTAssertNil(command.problem)
    }

    /// A typo must not stop `--help` from answering, which is the reason the
    /// parser records a problem instead of throwing at the first one.
    func testHelpSurvivesABadFlagOnTheSameLine() {
        let command = HangarCommand.parse(["--wat", "--help"])
        XCTAssertTrue(command.help)
        XCTAssertNotNil(command.problem)
    }

    func testSearchTextTrimsAndJoins() {
        XCTAssertEqual(HangarCommand.parse(["  web  "]).searchText, "web")
        XCTAssertEqual(HangarCommand.parse([]).searchText, "")
    }
}
