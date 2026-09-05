import XCTest
@testable import HangarCore

/// `-f` clauses. The questions people actually ask are "prod or staging" and
/// "anything except the canaries", and the dictionary form could express
/// neither.
final class HostFilterTests: XCTestCase {

    private func host(_ tags: [String: String], state: String = "running") -> Instance {
        Fixture.instance(tags, state: state)
    }

    private func parsed(_ text: String) throws -> HostFilter {
        guard case .filter(let filter) = HostFilter.parse(text) else {
            throw XCTSkip("'\(text)' did not parse as a filter")
        }
        return filter
    }

    // MARK: - Parsing

    func testPlainKeyEqualsValue() throws {
        XCTAssertEqual(try parsed("env=prod"),
                       HostFilter(key: "env", patterns: ["prod"], match: .any))
    }

    func testCommaSeparatesAlternatives() throws {
        XCTAssertEqual(try parsed("env=prod,staging"),
                       HostFilter(key: "env", patterns: ["prod", "staging"], match: .any))
    }

    func testBangEqualsNegates() throws {
        XCTAssertEqual(try parsed("env!=prod"),
                       HostFilter(key: "env", patterns: ["prod"], match: .none))
    }

    func testNegationTakesAListToo() throws {
        XCTAssertEqual(try parsed("env!=prod,staging"),
                       HostFilter(key: "env", patterns: ["prod", "staging"], match: .none))
    }

    /// Only the first `=` splits, so a value may contain one.
    func testValueMayContainEquals() throws {
        XCTAssertEqual(try parsed("tag=a=b").patterns, ["a=b"])
    }

    /// A tag value with a comma in it has to stay reachable, or it is a value
    /// nobody can filter on.
    func testBackslashEscapesAComma() throws {
        XCTAssertEqual(try parsed(#"team=a\,b"#).patterns, ["a,b"])
        XCTAssertEqual(try parsed(#"team=a\,b,c"#).patterns, ["a,b", "c"])
    }

    /// Every other backslash is part of the value rather than vanishing.
    func testBackslashBeforeAnythingElseSurvives() throws {
        XCTAssertEqual(try parsed(#"path=a\b"#).patterns, [#"a\b"#])
        XCTAssertEqual(try parsed(#"path=a\"#).patterns, [#"a\"#])
    }

    func testMissingEqualsIsAProblem() {
        XCTAssertEqual(HostFilter.parse("env"),
                       .problem("--filter takes key=value or key!=value, not 'env'"))
    }

    func testEmptyKeyIsAProblem() {
        XCTAssertEqual(HostFilter.parse("=prod"),
                       .problem("--filter takes key=value or key!=value, not '=prod'"))
        XCTAssertEqual(HostFilter.parse("!=prod"),
                       .problem("--filter takes key=value or key!=value, not '!=prod'"))
    }

    /// A stray comma left an empty alternative in the list, and an empty pattern
    /// is the wildcard, so the clause quietly became true for every host and the
    /// values either side of it said nothing. Silent and wrong is the worst of
    /// the three outcomes, so it is reported.
    func testAnEmptyAlternativeIsReported() {
        for text in ["env=prod,", "env=,prod", "env=prod,,qa", "env=,"] {
            guard case .problem(let problem) = HostFilter.parse(text) else {
                return XCTFail("'\(text)' parsed as a filter")
            }
            XCTAssertTrue(problem.contains(text), problem)
            XCTAssertTrue(problem.contains("every host"), problem)
        }
    }

    func testAnEmptyAlternativeIsReportedWhenNegatedToo() {
        guard case .problem = HostFilter.parse("env!=prod,") else {
            return XCTFail("a negated clause kept its empty alternative")
        }
    }

    /// The regression in one line: this used to list the whole fleet.
    func testAStrayCommaCannotMatchEveryHost() {
        let fleet = entries([host(["env": "prod"]), host(["env": "qa"]),
                             host(["env": "stage"])])
        guard case .filter(let good) = HostFilter.parse("env=prod") else {
            return XCTFail("the well formed clause did not parse")
        }
        XCTAssertEqual(FleetIndex.filtered(fleet, by: [good]).count, 1)
        // And the malformed one never reaches a filter at all.
        guard case .problem = HostFilter.parse("env=prod,") else {
            return XCTFail("the stray comma produced a filter")
        }
    }

    /// An empty value still parses, and still means "anything", which is what the
    /// wildcard rule has always done.
    func testEmptyValueKeepsItsOldMeaning() throws {
        XCTAssertTrue(try parsed("env=").matches(host(["env": "prod"])))
        XCTAssertTrue(try parsed("env=").matches(host([:])))
    }

    // MARK: - Matching

    func testAnyMatchesEitherAlternativeAndNothingElse() throws {
        let filter = try parsed("env=prod,staging")
        XCTAssertTrue(filter.matches(host(["env": "prod"])))
        XCTAssertTrue(filter.matches(host(["env": "staging"])))
        XCTAssertFalse(filter.matches(host(["env": "qa"])))
        XCTAssertFalse(filter.matches(host([:])))
    }

    func testNoneExcludesAndKeepsTheRest() throws {
        let filter = try parsed("env!=prod")
        XCTAssertFalse(filter.matches(host(["env": "prod"])))
        XCTAssertTrue(filter.matches(host(["env": "qa"])))
        // A host with no env at all is not prod, so it stays.
        XCTAssertTrue(filter.matches(host([:])))
    }

    func testWildcardsWorkOnBothSidesOfTheNegation() throws {
        XCTAssertTrue(try parsed("Name=*canary*").matches(host(["Name": "web-canary-1"])))
        XCTAssertFalse(try parsed("Name!=*canary*").matches(host(["Name": "web-canary-1"])))
        XCTAssertTrue(try parsed("Name!=*canary*").matches(host(["Name": "web-1"])))
    }

    /// The friendly names `tagValue(for:)` resolves work here too, which is how
    /// `state` and `name` became filterable without being tags.
    func testFriendlyKeys() throws {
        XCTAssertTrue(try parsed("state=running").matches(host([:], state: "running")))
        XCTAssertFalse(try parsed("state=running").matches(host([:], state: "stopped")))
        XCTAssertTrue(try parsed("state!=terminated").matches(host([:], state: "running")))
        XCTAssertTrue(try parsed("name=web").matches(host(["Name": "web"])))
    }

    func testAnEscapedCommaMatchesAValueContainingOne() throws {
        XCTAssertTrue(try parsed(#"owner=smith\, jane"#)
            .matches(host(["owner": "smith, jane"])))
    }

    // MARK: - Applied to a fleet

    private func entries(_ instances: [Instance]) -> [SearchEntry] {
        instances.enumerated().map { SearchEntry(instance: $1, alias: "host-\($0)") }
    }

    func testClausesAreAnded() throws {
        let fleet = entries([
            host(["env": "prod", "product": "web"]),
            host(["env": "prod", "product": "db"]),
            host(["env": "qa", "product": "web"]),
        ])
        let matched = FleetIndex.filtered(fleet, by: [try parsed("env=prod"),
                                                      try parsed("product=web")])
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.instance.product, "web")
    }

    /// Two clauses on the same key both apply, which is the point of the array.
    func testTwoClausesOnOneKeyBothApply() throws {
        let fleet = entries([
            host(["Name": "web-1"]), host(["Name": "web-canary"]), host(["Name": "db-1"]),
        ])
        let matched = FleetIndex.filtered(fleet, by: [try parsed("name=web*"),
                                                      try parsed("name!=*canary*")])
        XCTAssertEqual(matched.map(\.instance.role), ["web-1"])
    }

    func testNoClausesFiltersNothing() {
        let fleet = entries([host(["env": "prod"]), host(["env": "qa"])])
        XCTAssertEqual(FleetIndex.filtered(fleet, by: [] as [HostFilter]).count, 2)
    }

    /// The dictionary form is what hotkey filters in the config file use, and it
    /// still answers exactly as it did.
    func testTheDictionaryFormIsUnchanged() {
        let fleet = entries([host(["env": "prod"]), host(["env": "qa"])])
        XCTAssertEqual(FleetIndex.filtered(fleet, by: ["env": "prod"]).count, 1)
        XCTAssertEqual(FleetIndex.filtered(fleet, by: ["env": "*"]).count, 2)
        XCTAssertEqual(FleetIndex.filtered(fleet, by: nil).count, 2)
    }
}
