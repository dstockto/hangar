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
        XCTAssertEqual(HangarCommand.parse(["-f", "env=prod"]).filters,
                       [HostFilter(key: "env", patterns: ["prod"])])
        // The value may contain an equals sign; only the first splits.
        XCTAssertEqual(HangarCommand.parse(["-f", "tag=a=b"]).filters,
                       [HostFilter(key: "tag", patterns: ["a=b"])])
    }

    /// Two clauses on one key both survive. The dictionary this replaced kept
    /// only the second, silently.
    func testFiltersAccumulateInOrder() {
        let command = HangarCommand.parse(["-f", "env=prod", "-f", "env!=canary"])
        XCTAssertEqual(command.filters, [HostFilter(key: "env", patterns: ["prod"]),
                                         HostFilter(key: "env", patterns: ["canary"],
                                                    match: .none)])
    }

    func testFilterRejectsAnythingElse() {
        XCTAssertEqual(HangarCommand.parse(["-f", "env"]).problem,
                       "--filter takes key=value or key!=value, not 'env'")
        XCTAssertEqual(HangarCommand.parse(["-f", "=prod"]).problem,
                       "--filter takes key=value or key!=value, not '=prod'")
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
        XCTAssertEqual(command.filters, [HostFilter(key: "env", patterns: ["prod"])])
        XCTAssertEqual(command.limit, 3)
        XCTAssertEqual(command.searchText, "web")
        XCTAssertEqual(command.cache, "/tmp/c")
        XCTAssertNil(command.problem)
    }

    /// The parser reads the whole line before deciding, rather than throwing at
    /// the first thing wrong, so both are recorded.
    func testABadFlagAndHelpAreBothRecorded() {
        let command = HangarCommand.parse(["--wat", "--help"])
        XCTAssertTrue(command.help)
        XCTAssertNotNil(command.problem)
    }

    // MARK: - Commands

    func testNoVerbIsAListing() {
        XCTAssertEqual(HangarCommand.parse([]).verb, .list)
        XCTAssertEqual(HangarCommand.parse(["web"]).verb, .list)
    }

    func testTheFirstPlainWordNamesTheCommand() {
        XCTAssertEqual(HangarCommand.parse(["tags"]).verb, .tags)
        XCTAssertEqual(HangarCommand.parse(["values", "env"]).verb, .values)
        XCTAssertEqual(HangarCommand.parse(["values", "env"]).valuesKey, "env")
    }

    /// Options before the command are ordinary, so this has to keep working.
    func testAnOptionMayComeBeforeTheCommand() {
        let command = HangarCommand.parse(["--json", "--cache", "/tmp/c", "tags"])
        XCTAssertEqual(command.verb, .tags)
        XCTAssertEqual(command.format, .json)
        XCTAssertEqual(command.cache, "/tmp/c")
    }

    /// Only the first plain word. A second one is a query or an argument, never
    /// another command.
    func testAWordAfterTheFirstIsNeverACommand() {
        let command = HangarCommand.parse(["web", "tags"])
        XCTAssertEqual(command.verb, .list)
        XCTAssertEqual(command.searchText, "web tags")
    }

    /// Both escapes reach a host named after a command. Without one of these, a
    /// fleet with a host called "tags" would have a host it cannot search for.
    func testSearchFlagIsAnEscapeFromAVerb() {
        let command = HangarCommand.parse(["-s", "tags"])
        XCTAssertEqual(command.verb, .list)
        XCTAssertEqual(command.searchText, "tags")
    }

    func testDoubleHyphenIsAnEscapeFromAVerb() {
        let command = HangarCommand.parse(["--", "tags"])
        XCTAssertEqual(command.verb, .list)
        XCTAssertEqual(command.searchText, "tags")
    }

    /// Nothing after `--` is an option either, so a host whose name starts with
    /// a hyphen is reachable and is not reported as a typo.
    func testNothingAfterDoubleHyphenIsAnOption() {
        let command = HangarCommand.parse(["--", "--json", "-f"])
        XCTAssertEqual(command.format, .columns)
        XCTAssertEqual(command.query, ["--json", "-f"])
        XCTAssertNil(command.problem)
    }

    func testValuesNeedsExactlyOneKey() {
        XCTAssertEqual(HangarCommand.parse(["values"]).problem,
                       "values needs a tag key, as in 'hangar values env'")
        XCTAssertEqual(HangarCommand.parse(["values", "env", "prod"]).problem,
                       "values takes one tag key, not 2")
        XCTAssertNil(HangarCommand.parse(["values", "env"]).problem)
    }

    /// Flags that narrow a listing mean nothing to a command that counts the
    /// whole fleet, and taking them silently is how somebody believes they asked
    /// a narrower question than they did.
    func testNarrowingFlagsAreRefusedByTheCountingCommands() {
        XCTAssertEqual(HangarCommand.parse(["values", "env", "-f", "product=web"]).problem,
                       "-f narrows a listing; 'hangar values' counts the whole fleet")
        XCTAssertEqual(HangarCommand.parse(["tags", "-f", "env=prod"]).problem,
                       "-f narrows a listing; 'hangar tags' counts the whole fleet")
        XCTAssertEqual(HangarCommand.parse(["values", "env", "-n", "2"]).problem,
                       "-n limits a listing; 'hangar values' counts the whole fleet")
        XCTAssertEqual(HangarCommand.parse(["tags", "-n", "3"]).problem,
                       "-n limits a listing; 'hangar tags' counts the whole fleet")
    }

    /// A listing still takes both, and the output flags still work everywhere.
    func testNarrowingFlagsAreFineOnAListing() {
        XCTAssertNil(HangarCommand.parse(["-f", "env=prod", "-n", "2"]).problem)
        XCTAssertNil(HangarCommand.parse(["tags", "--json"]).problem)
        XCTAssertNil(HangarCommand.parse(["values", "env", "-a"]).problem)
    }

    func testTagsTakesNoArguments() {
        XCTAssertEqual(HangarCommand.parse(["tags", "env"]).problem,
                       "tags takes no arguments; did you mean 'hangar values env'?")
    }

    /// Asking a command for help is a question, not a mistake.
    func testHelpBeatsAMissingArgument() {
        XCTAssertNil(HangarCommand.parse(["values", "--help"]).problem)
        XCTAssertTrue(HangarCommand.parse(["values", "--help"]).help)
    }

    // MARK: - Connecting

    func testSshIsAVerbAndTakesAQuery() {
        let command = HangarCommand.parse(["ssh", "web", "prod"])
        XCTAssertEqual(command.verb, .ssh)
        XCTAssertEqual(command.searchText, "web prod")
        XCTAssertNil(command.problem)
    }

    func testFirstAndDryRunAreFlags() {
        XCTAssertTrue(HangarCommand.parse(["ssh", "web", "-1"]).first)
        XCTAssertTrue(HangarCommand.parse(["ssh", "web", "--first"]).first)
        XCTAssertTrue(HangarCommand.parse(["ssh", "web", "--dry-run"]).dryRun)
        XCTAssertFalse(HangarCommand.parse(["ssh", "web"]).first)
        XCTAssertFalse(HangarCommand.parse(["ssh", "web"]).dryRun)
    }

    /// `-1` starts with a hyphen and would otherwise be reported as a typo.
    func testDashOneIsAFlagNotAnUnknownOption() {
        XCTAssertNil(HangarCommand.parse(["ssh", "web", "-1"]).problem)
    }

    /// Without a query or a filter every host matches, so --first would open a
    /// session on whatever sorts first. "The best match" needs a match.
    func testSshNeedsSomethingToMatchOn() {
        XCTAssertEqual(HangarCommand.parse(["ssh"]).problem,
                       "ssh needs a query or a filter, as in 'hangar ssh web prod'")
        XCTAssertEqual(HangarCommand.parse(["ssh", "-1"]).problem,
                       "ssh needs a query or a filter, as in 'hangar ssh web prod'")
        XCTAssertNil(HangarCommand.parse(["ssh", "web"]).problem)
        XCTAssertNil(HangarCommand.parse(["ssh", "-f", "env=prod"]).problem)
    }

    /// Narrowing an ssh selection is the point of it, so the counting-command
    /// refusal must not reach here.
    func testSshTakesFiltersAndLimits() {
        XCTAssertNil(HangarCommand.parse(["ssh", "web", "-f", "env=prod"]).problem)
        XCTAssertNil(HangarCommand.parse(["ssh", "web", "-n", "5"]).problem)
    }

    func testValuesKeyIsOnlySetForThatCommand() {
        XCTAssertNil(HangarCommand.parse(["web"]).valuesKey)
        XCTAssertNil(HangarCommand.parse(["tags"]).valuesKey)
    }

    func testSearchTextTrimsAndJoins() {
        XCTAssertEqual(HangarCommand.parse(["  web  "]).searchText, "web")
        XCTAssertEqual(HangarCommand.parse([]).searchText, "")
    }
}
