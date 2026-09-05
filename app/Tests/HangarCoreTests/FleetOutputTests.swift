import XCTest
@testable import HangarCore

/// The bytes the `hangar` command writes. These are what a pipeline downstream
/// of it is actually parsing, so they are asserted exactly.
final class FleetOutputTests: XCTestCase {

    private func entry(_ alias: String, product: String = "payments",
                       env: String = "prod", state: String = "running",
                       id: String = "i-0123456789abcdef0") -> SearchEntry {
        var instance = Fixture.instance(
            ["product": product, "env": env, "Name": "web"], id: id, state: state)
        instance.tags["hostname"] = "\(alias).example.com"
        return SearchEntry(instance: instance, alias: alias)
    }

    // MARK: - Columns

    func testColumnsPadsToTheWidestAliasAndGroup() {
        let text = FleetOutput.columns([entry("web-1"), entry("a-very-long-alias")])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Padded to the widest alias, then two spaces, so the second column of
        // every row starts at the same offset.
        let gap = String(repeating: " ", count: "a-very-long-alias".count - "web-1".count)
        XCTAssertEqual(lines[0],
                       "web-1\(gap)  payments\u{00B7}prod  web-1.example.com")
        XCTAssertEqual(lines[1],
                       "a-very-long-alias  payments\u{00B7}prod  a-very-long-alias.example.com")
    }

    func testColumnsJoinsProductAndEnvironmentWithAMiddleDot() {
        XCTAssertTrue(FleetOutput.columns([entry("web-1")]).contains("payments\u{00B7}prod"))
    }

    /// A host carrying neither leaves the column empty rather than printing a
    /// stray separator.
    func testColumnsOmitsAnAbsentHalfOfTheGroup() {
        XCTAssertEqual(FleetOutput.group(entry("web-1", product: "", env: "prod")), "prod")
        XCTAssertEqual(FleetOutput.group(entry("web-1", product: "payments", env: "")),
                       "payments")
        XCTAssertEqual(FleetOutput.group(entry("web-1", product: "", env: "")), "")
    }

    func testEveryShapeEndsWithExactlyOneNewline() {
        for text in [FleetOutput.columns([entry("web-1")]),
                     FleetOutput.aliases([entry("web-1")]),
                     FleetOutput.tsv([entry("web-1")])] {
            XCTAssertTrue(text.hasSuffix("\n"))
            XCTAssertFalse(text.hasSuffix("\n\n"))
        }
    }

    /// Nothing prints as nothing. A blank line would reach `wc -l` as a host.
    func testNothingPrintsAsNothing() {
        XCTAssertEqual(FleetOutput.columns([]), "")
        XCTAssertEqual(FleetOutput.aliases([]), "")
        XCTAssertEqual(FleetOutput.tsv([]), "")
    }

    // MARK: - Aliases

    func testAliasesAreOnePerLineAndNothingElse() {
        XCTAssertEqual(FleetOutput.aliases([entry("web-1"), entry("web-2")]),
                       "web-1\nweb-2\n")
    }

    // MARK: - TSV

    func testTSVColumnsAreTheDocumentedOrder() {
        let text = FleetOutput.tsv([entry("web-1", id: "i-abc")])
        XCTAssertEqual(text, "web-1\tweb-1.example.com\tpayments\tprod\trunning\ti-abc\n")
    }

    func testTSVIsTabSeparatedSoAwkCanCutIt() {
        let fields = FleetOutput.tsv([entry("web-1")])
            .trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        XCTAssertEqual(fields.count, 6)
    }

    // MARK: - Fields

    func testFieldsCarriesTheNamesTheDocumentationUses() {
        let row = FleetOutput.fields(entry("web-1", id: "i-abc"))
        XCTAssertEqual(row["alias"], "web-1")
        XCTAssertEqual(row["hostname"], "web-1.example.com")
        XCTAssertEqual(row["product"], "payments")
        XCTAssertEqual(row["env"], "prod")
        XCTAssertEqual(row["role"], "web")
        XCTAssertEqual(row["id"], "i-abc")
        XCTAssertEqual(row["state"], "running")
        XCTAssertEqual(row["private_ip"], "10.0.0.1")
        XCTAssertEqual(row["zone"], "us-west-2a")
        XCTAssertEqual(row["command"], "ssh web-1")
    }

    /// An absent address is an empty string, never the word "nil".
    func testAbsentValuesAreEmptyStrings() {
        let row = FleetOutput.fields(entry("web-1"))
        XCTAssertEqual(row["public_ip"], "")
    }

    // MARK: - JSON

    func testJSONIsOneArrayOfObjects() throws {
        let text = try XCTUnwrap(FleetOutput.json([entry("web-1"), entry("web-2")]))
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let rows = try XCTUnwrap(parsed as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["alias"] as? String, "web-1")
    }

    func testJSONEndsWithANewline() throws {
        XCTAssertTrue(try XCTUnwrap(FleetOutput.json([entry("web-1")])).hasSuffix("\n"))
    }

    // MARK: - Dispatch

    func testRenderedPicksTheShapeTheCommandAskedFor() {
        let entries = [entry("web-1")]
        XCTAssertEqual(FleetOutput.rendered(entries, as: .alias),
                       FleetOutput.aliases(entries))
        XCTAssertEqual(FleetOutput.rendered(entries, as: .tsv), FleetOutput.tsv(entries))
        XCTAssertEqual(FleetOutput.rendered(entries, as: .columns),
                       FleetOutput.columns(entries))
        XCTAssertEqual(FleetOutput.rendered(entries, as: .json), FleetOutput.json(entries))
    }

    // MARK: - Why nothing came back

    /// Mistake 26: a number on screen has to name the set it counted. A filter
    /// that matched nothing used to report an empty cache, sending the reader to
    /// refresh a fleet that was already there.
    func testAFilterThatMatchedNothingDoesNotBlameTheCache() {
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "", filters: 1, fleetSize: 249),
            "no host matched that filter, out of 249.")
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "", filters: 3, fleetSize: 249),
            "no host matched those 3 filters, out of 249.")
    }

    func testAQueryThatMatchedNothingKeepsItsOldWording() {
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "web", filters: 0, fleetSize: 249),
            "nothing matched \"web\" in 249 hosts.")
    }

    func testAQueryAndAFilterNameBoth() {
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "web", filters: 2, fleetSize: 249),
            "nothing matched \"web\" with those 2 filters in 249 hosts.")
    }

    /// Nothing narrowed it and the fleet is not empty, which main.swift cannot
    /// reach: with no query and no filters the match is the whole fleet. It is
    /// public API though, and "those 0 filters" is not a sentence.
    func testNoQueryAndNoFilterDoesNotCountFiltersNobodyPassed() {
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "", filters: 0, fleetSize: 249),
            "no host matched, out of 249.")
    }

    /// The one case where blaming the cache is the truth.
    func testAnEmptyCacheStillSaysSo() {
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "", filters: 0, fleetSize: 0),
            "the cached fleet is empty.")
        XCTAssertEqual(
            FleetOutput.nothingMatched(query: "web", filters: 1, fleetSize: 0),
            "the cached fleet is empty.")
    }
}
