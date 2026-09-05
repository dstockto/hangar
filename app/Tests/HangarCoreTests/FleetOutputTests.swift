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

    /// The one promise here that used to be false. Nothing matching is an answer,
    /// so it has to parse; the exit code is what says nothing matched.
    func testNothingMatchingIsStillAValidDocument() throws {
        let text = try XCTUnwrap(FleetOutput.json([]))
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        XCTAssertEqual(try XCTUnwrap(parsed as? [Any]).count, 0)
        XCTAssertEqual(text, "[]\n")
    }

    func testJSONCarriesTheFieldsAFlatMapCannotHold() throws {
        var instance = Fixture.instance(["product": "payments", "env": "prod",
                                         "team": "platform"])
        instance.cores = 2
        instance.threadsPerCore = 2
        instance.lifecycle = "spot"
        instance.privateDNS = "ip-10-0-0-1.internal"
        instance.tags["aws:autoscaling:groupName"] = "payments-web"
        let row = try firstRow(SearchEntry(instance: instance, alias: "web-1"))

        XCTAssertEqual(row["type"] as? String, "t3.small")
        XCTAssertEqual(row["launch_time"] as? String, "2026-08-20T15:46:42.000Z")
        XCTAssertEqual(row["asg"] as? String, "payments-web")
        XCTAssertEqual(row["lifecycle"] as? String, "spot")
        XCTAssertEqual(row["private_dns"] as? String, "ip-10-0-0-1.internal")
    }

    /// A number, so a reader filtering on size does not parse a string first.
    func testVCPUsIsANumber() throws {
        var instance = Fixture.instance([:])
        instance.cores = 4
        instance.threadsPerCore = 2
        let row = try firstRow(SearchEntry(instance: instance, alias: "web-1"))
        XCTAssertEqual(row["vcpus"] as? Int, 8)
    }

    /// Absent rather than zero: a response that did not say how the cores are
    /// laid out is not a host with none.
    func testVCPUsIsAbsentWhenUnknown() throws {
        let row = try firstRow(entry("web-1"))
        XCTAssertNil(row["vcpus"])
    }

    /// The tag map, so "everything in the payments ASG" and "the m5.large ones"
    /// are answerable from the document. It is the map after the mapping resolved
    /// it, which is the same map `-f` filters against.
    func testTagsAreNestedWhole() throws {
        let row = try firstRow(entry("web-1"))
        let tags = try XCTUnwrap(row["tags"] as? [String: String])
        XCTAssertEqual(tags["product"], "payments")
        XCTAssertEqual(tags["Name"], "web")
    }

    /// A tag the mapping has no candidate for is passed through untouched, which
    /// is what makes filtering on a fleet's own vocabulary possible.
    func testATagTheMappingDoesNotKnowSurvives() throws {
        var instance = Fixture.instance(["product": "payments", "team": "platform"])
        instance.tags["cost-centre"] = "4021"
        let row = try firstRow(SearchEntry(instance: instance, alias: "web-1"))
        let tags = try XCTUnwrap(row["tags"] as? [String: String])
        XCTAssertEqual(tags["team"], "platform")
        XCTAssertEqual(tags["cost-centre"], "4021")
    }

    /// The document publishes every tag, but `-f` resolves nine key names rather
    /// than looking them up, so a fleet with its own `Role` tag can see it here
    /// and not be able to select on it. Pinned because the README promised
    /// otherwise, and the promise was the thing that was wrong.
    func testATagCanBeInTheDocumentAndNotSelectableByItsOwnKey() throws {
        let instance = Fixture.instance(["Name": "web-1", "Role": "api-gateway"])
        let row = try firstRow(SearchEntry(instance: instance, alias: "web-1"))
        let tags = try XCTUnwrap(row["tags"] as? [String: String])
        XCTAssertEqual(tags["Role"], "api-gateway")
        // What -f would match on instead: the resolved role, from the Name tag.
        XCTAssertEqual(instance.tagValue(for: "Role"), "web-1")
        XCTAssertEqual(instance.tagValue(for: "role"), "web-1")
    }

    /// A tag value is written by anyone who can tag the account. It has to come
    /// back as one string rather than breaking the document.
    func testAnAwkwardTagValueSurvivesEncoding() throws {
        var instance = Fixture.instance(["product": "payments"])
        instance.tags["note"] = "quote \" backslash \\ newline \n done"
        let row = try firstRow(SearchEntry(instance: instance, alias: "web-1"))
        let tags = try XCTUnwrap(row["tags"] as? [String: String])
        XCTAssertEqual(tags["note"], "quote \" backslash \\ newline \n done")
    }

    /// Parses what `json` produced, which is what a reader downstream actually
    /// gets, rather than trusting the dictionary that went in.
    private func firstRow(_ entry: SearchEntry) throws -> [String: Any] {
        let text = try XCTUnwrap(FleetOutput.json([entry]))
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap((parsed as? [[String: Any]])?.first)
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

    // MARK: - Tag keys and values

    private var catalog: TagCatalog {
        TagCatalog.discover(from: [
            Fixture.instance(["env": "prod", "team": "platform"]),
            Fixture.instance(["env": "prod"]),
        ])
    }

    func testTagKeysAsAliasesAreTheKeyNamesAlone() {
        XCTAssertEqual(FleetOutput.tagKeys(catalog, as: .alias), "env\nteam\n")
    }

    /// Five columns: key, hosts, distinct values, samples, and whether `-f`
    /// resolves that name rather than reading the tag. `env` is one of the nine.
    func testTagKeysAsTSVCarryCountsSamplesAndTheResolvedMarker() {
        XCTAssertEqual(FleetOutput.tagKeys(catalog, shadowed: ["env"], as: .tsv),
                       "env\t2\t1\tprod\tresolved\nteam\t1\t1\tplatform\t\n")
    }

    /// The marker is the whole point of the row: a fleet's own `Role` tag is
    /// listed here and is not selectable by that key. The formatter renders what
    /// it is told; which keys those are is `TagCatalog.shadowedKeys`.
    func testTagKeysMarkTheNamesFilteringResolvesPast() throws {
        let fleet = TagCatalog.discover(from: [
            Fixture.instance(["Role": "api-gateway", "team": "platform"]),
        ])
        let text = try XCTUnwrap(FleetOutput.tagKeys(fleet, shadowed: ["Role"],
                                                     as: .json))
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["key"] as! String, $0["resolved_by_filter"] as! Bool)
        })
        XCTAssertEqual(byKey["Role"], true)
        XCTAssertEqual(byKey["team"], false)
    }

    /// Said once under the table, and only when a row needs it. For a person,
    /// like the header: a pipe takes the same fact per row from --json or --tsv.
    func testColumnsFooterNamesTheResolvedKeys() throws {
        let interactive = Terminal(isInteractive: true, isColoured: false)
        let text = try XCTUnwrap(FleetOutput.tagKeys(catalog, shadowed: ["env"],
                                                     as: .columns,
                                                     terminal: interactive))
        XCTAssertTrue(text.contains("-f resolves these names"))
        XCTAssertTrue(text.contains("env"))

        // Nothing shadowed, so no footer. This is the regression: the marker used
        // to fire on env and product from a list of names, and both filter.
        XCTAssertFalse(try XCTUnwrap(FleetOutput.tagKeys(catalog, shadowed: [],
                                                         as: .columns,
                                                         terminal: interactive))
            .contains("-f resolves"))

        // A pipe gets rows and nothing else.
        XCTAssertFalse(try XCTUnwrap(FleetOutput.tagKeys(catalog, shadowed: ["env"],
                                                         as: .columns,
                                                         terminal: .plain))
            .contains("-f resolves"))
    }

    func testTagKeysAsJSONAreAnArrayOfObjects() throws {
        let text = try XCTUnwrap(FleetOutput.tagKeys(catalog, as: .json))
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.first?["key"] as? String, "env")
        XCTAssertEqual(rows.first?["hosts"] as? Int, 2)
        XCTAssertEqual(rows.first?["distinct_values"] as? Int, 1)
        XCTAssertEqual(rows.first?["samples"] as? [String], ["prod"])
    }

    func testTagValuesAsAliasesAreTheValuesAlone() {
        let counts = [TagCatalog.ValueCount(value: "prod", hosts: 3),
                      TagCatalog.ValueCount(value: "qa", hosts: 1)]
        XCTAssertEqual(FleetOutput.tagValues(counts, as: .alias), "prod\nqa\n")
    }

    func testTagValuesInColumnsRightAlignTheCounts() {
        let counts = [TagCatalog.ValueCount(value: "prod", hosts: 3),
                      TagCatalog.ValueCount(value: "staging", hosts: 42)]
        // Value padded to the widest, then the count right-aligned under itself.
        XCTAssertEqual(FleetOutput.tagValues(counts, as: .columns),
                       "prod          3\nstaging      42\n")
    }

    /// Same rule as the host listing: an empty answer is still a document.
    func testEmptyTagOutputIsStillADocument() {
        XCTAssertEqual(FleetOutput.tagKeys(.empty, as: .json), "[]\n")
        XCTAssertEqual(FleetOutput.tagValues([], as: .json), "[]\n")
        XCTAssertEqual(FleetOutput.tagValues([], as: .columns), "")
    }

    // MARK: - The listing a person reads

    private var tty: Terminal { Terminal(isInteractive: true, isColoured: true) }
    private var monochrome: Terminal { Terminal(isInteractive: true, isColoured: false) }

    /// The promise that makes this safe to add at all: a pipeline gets exactly
    /// the bytes it has always got.
    func testAPipeGetsTheOldListingByteForByte() {
        let entries = [entry("web-1"), entry("web-2", env: "qa", state: "stopped")]
        XCTAssertEqual(FleetOutput.listing(entries, terminal: .plain, grouped: true),
                       FleetOutput.columns(entries))
        XCTAssertEqual(FleetOutput.listing(entries, terminal: .plain, grouped: false),
                       FleetOutput.columns(entries))
    }

    func testATerminalGetsGroupHeadings() {
        let entries = [entry("web-1"), entry("web-2"),
                       entry("api-1", product: "search")]
        let lines = FleetOutput.listing(entries, terminal: monochrome, grouped: true)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "payments\u{00B7}prod")
        XCTAssertEqual(lines[1], "  web-1  web-1.example.com")
        XCTAssertEqual(lines[2], "  web-2  web-2.example.com")
        XCTAssertEqual(lines[3], "")
        XCTAssertEqual(lines[4], "search\u{00B7}prod")
    }

    /// A ranked list is in relevance order, and a heading over it would either
    /// lie about that order or throw the ranking away.
    func testASearchIsNotGrouped() {
        let entries = [entry("web-1"), entry("api-1", product: "search")]
        let text = FleetOutput.listing(entries, terminal: monochrome, grouped: false)
        XCTAssertFalse(text.contains("\n\n"))
        // The group is still a column, so a flat list does not lose the context.
        XCTAssertTrue(text.contains("payments\u{00B7}prod"))
    }

    /// A fleet nothing groups gets no headings at all. `FleetGrouping` refuses to
    /// draw one group holding everything, and the README promises that nothing
    /// produces an "untagged" level containing the whole fleet. A flat
    /// ssh_config fleet of single-component names reaches exactly this.
    func testAFleetNothingGroupsGetsNoHeadings() {
        let entries = [entry("box1", product: "", env: ""),
                       entry("nas", product: "", env: "")]
        let text = FleetOutput.listing(entries, terminal: monochrome, grouped: true)
        XCTAssertFalse(text.contains("untagged"))
        XCTAssertTrue(text.contains("box1"))
        XCTAssertTrue(text.contains("nas"))
    }

    /// When other hosts do carry a level, one that carries none sits under a
    /// name rather than under nothing. That is FleetGrouping's rule too.
    func testAnUngroupedHostAmongGroupedOnesIsNamed() {
        let entries = [entry("web-1"), entry("orphan", product: "", env: "")]
        XCTAssertTrue(FleetOutput.listing(entries, terminal: monochrome, grouped: true)
            .contains("untagged"))
    }

    /// The headings follow the configured levels, because the menu does. Stock
    /// config is three levels, and a fleet carrying env_name draws all three.
    func testHeadingsUseTheConfiguredLevels() {
        var instance = Fixture.instance(["product": "payments", "env": "prod",
                                         "env_name": "blue", "Name": "web"])
        instance.tags["hostname"] = "web-1.example.com"
        let entries = [SearchEntry(instance: instance, alias: "web-1")]
        XCTAssertTrue(FleetOutput.listing(entries, terminal: monochrome, grouped: true)
            .hasPrefix("payments\u{00B7}prod\u{00B7}blue"))
    }

    /// The regression a single-entry test cannot see. Rows arrive in
    /// FleetIndex.sortKey order (product, env), and with group_by ["Team"] the
    /// headings interleave: platform, infra, platform. A run detector prints the
    /// first heading twice and severs its two hosts.
    func testAHeadingIsNeverPrintedTwice() {
        func host(_ alias: String, _ product: String, _ team: String) -> SearchEntry {
            var instance = Fixture.instance(["product": product, "env": "prod"])
            instance.tags["Team"] = team
            instance.tags["hostname"] = "\(alias).example.com"
            return SearchEntry(instance: instance, alias: alias)
        }
        // Deliberately in sortKey order, which is what main.swift hands over.
        let entries = [host("payments-web", "payments", "platform"),
                       host("search-api", "search", "infra"),
                       host("web-1", "web", "platform")]
        let lines = FleetOutput.listing(entries, terminal: monochrome, grouped: true,
                                        groupBy: ["Team"])
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headings = lines.filter { !$0.hasPrefix("  ") && !$0.isEmpty }
        XCTAssertEqual(headings, ["platform", "infra"])

        // And the two platform hosts stay together under their one heading.
        let platform = lines.drop { $0 != "platform" }.dropFirst()
            .prefix { $0.hasPrefix("  ") }
        XCTAssertEqual(platform.count, 2)
        XCTAssertTrue(platform.contains { $0.contains("payments-web") })
        XCTAssertTrue(platform.contains { $0.contains("web-1") })
    }

    /// Mistake 23 under a custom grouping. sortKey keys untagged-last on
    /// product.isEmpty, which stops protecting anything once the heading leads
    /// with something else: a host with no Team but an early product is the
    /// first row handed over, and used to open the listing with "untagged".
    func testUntaggedSortsLastUnderACustomGrouping() {
        func host(_ alias: String, _ product: String, _ team: String?) -> SearchEntry {
            var instance = Fixture.instance(["product": product, "env": "prod"])
            if let team { instance.tags["Team"] = team }
            instance.tags["hostname"] = "\(alias).example.com"
            return SearchEntry(instance: instance, alias: alias)
        }
        // "aardvark" has no Team and sorts first by product, so it arrives first.
        let entries = [host("a-1", "aardvark", nil), host("z-1", "zebra", "platform")]
        let text = FleetOutput.listing(entries, terminal: monochrome, grouped: true,
                                       groupBy: ["Team"])
        XCTAssertTrue(text.hasPrefix("platform"), text)
        XCTAssertTrue(text.contains("untagged"))
        let headings = text.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("  ") }
        XCTAssertEqual(headings, ["platform", "untagged"])
    }

    /// A custom group_by is honoured, including a key Hangar does not map.
    func testACustomGroupingIsHonoured() {
        var instance = Fixture.instance(["product": "payments", "env": "prod"])
        instance.tags["Team"] = "growth"
        let entries = [SearchEntry(instance: instance, alias: "web-1")]
        let text = FleetOutput.listing(entries, terminal: monochrome, grouped: true,
                                       groupBy: ["Team", "env"])
        XCTAssertTrue(text.hasPrefix("growth\u{00B7}prod"), text)
        XCTAssertFalse(text.contains("payments"))
    }

    /// The piped shape is frozen at product and environment, because that is what
    /// 0.6.1 printed and something is parsing it.
    func testThePipedGroupColumnIsUnchangedByTheLevels() {
        let entries = [entry("web-1")]
        XCTAssertEqual(FleetOutput.listing(entries, terminal: .plain, grouped: true,
                                           groupBy: ["Team"]),
                       FleetOutput.columns(entries))
    }

    /// Colour never carries a fact on its own. A reader who cannot see the
    /// dimming, or who pasted the line somewhere else, gets the same answer.
    func testAStoppedHostSaysSoInWords() {
        let entries = [entry("web-1", state: "stopped")]
        let text = FleetOutput.listing(entries, terminal: monochrome, grouped: true)
        XCTAssertTrue(text.contains("stopped"))
    }

    func testARunningHostDoesNotSayItsState() {
        let entries = [entry("web-1", state: "running")]
        XCTAssertFalse(FleetOutput.listing(entries, terminal: monochrome, grouped: true)
            .contains("running"))
    }

    /// With colour off there is not one escape sequence anywhere, which is what
    /// NO_COLOR and TERM=dumb are asking for.
    func testColourOffProducesNoEscapeSequences() {
        let entries = [entry("web-1"), entry("web-2", state: "stopped"),
                       entry("api-1", product: "search")]
        for grouped in [true, false] {
            let text = FleetOutput.listing(entries, terminal: monochrome, grouped: grouped)
            XCTAssertFalse(text.contains("\u{1B}"))
        }
    }

    /// Nesting one sequence inside another would let the inner reset cancel the
    /// outer style for the rest of the row, so a dimmed row is styled once.
    func testADimmedRowIsStyledOnce() {
        let entries = [entry("web-1", state: "stopped")]
        let text = FleetOutput.listing(entries, terminal: tty, grouped: false)
        XCTAssertEqual(text.components(separatedBy: "\u{1B}[0m").count - 1, 1)
    }

    func testTagKeysGetAHeaderOnlyAtATerminal() throws {
        let plain = try XCTUnwrap(FleetOutput.tagKeys(catalog, as: .columns,
                                                      terminal: .plain))
        XCTAssertFalse(plain.contains("KEY"))
        let interactive = try XCTUnwrap(FleetOutput.tagKeys(catalog, as: .columns,
                                                            terminal: monochrome))
        XCTAssertTrue(interactive.hasPrefix("KEY"))
        XCTAssertTrue(interactive.contains("HOSTS"))
    }

    /// A header over nothing is a header describing nothing.
    func testNoHeaderWhenThereAreNoKeys() {
        XCTAssertEqual(FleetOutput.tagKeys(.empty, as: .columns, terminal: monochrome), "")
    }

    /// `padding(toLength:)` counts UTF-16 units while `count` counts characters,
    /// so a tag containing an emoji was measured as longer than it was asked to
    /// be and got cut instead of padded. Tag values come from whoever tags the
    /// account.
    func testAValueOutsideTheBasicPlaneIsPaddedAndNotCut() {
        XCTAssertEqual(FleetOutput.pad("\u{1F680}ab", to: 5), "\u{1F680}ab  ")
        XCTAssertEqual(FleetOutput.pad("\u{1F680}ab", to: 3), "\u{1F680}ab")
        XCTAssertEqual(FleetOutput.pad("caf\u{00E9}", to: 6), "caf\u{00E9}  ")
    }

    /// The case the first probe of this bug missed, and the one that matters:
    /// when the cut falls between an emoji's two UTF-16 halves the character is
    /// not truncated, it is replaced with U+FFFD. A single emoji at width 1 is
    /// the smallest input that does it.
    func testACutBetweenSurrogatesWouldReplaceTheCharacter() {
        let rocket = "\u{1F680}"
        // What the old implementation did, kept here as the reason for the new one.
        let cut = rocket.padding(toLength: max(1, rocket.count), withPad: " ",
                                 startingAt: 0)
        XCTAssertEqual(cut.unicodeScalars.map(\.value), [0xFFFD])

        // What pad does instead.
        XCTAssertEqual(FleetOutput.pad(rocket, to: 1), rocket)
        XCTAssertEqual(FleetOutput.pad(rocket, to: 3), rocket + "  ")
    }

    /// A grapheme built from several scalars is one character to `count` and five
    /// UTF-16 units to `padding`, which is the same trap one step further out.
    func testAMultiScalarGraphemeSurvives() {
        let family = "\u{1F468}\u{200D}\u{1F469}"
        XCTAssertEqual(FleetOutput.pad(family, to: 1), family)
        XCTAssertEqual(FleetOutput.pad(family, to: 2), family + " ")
    }

    /// The whole row, not just the helper: the emoji product used to lose a
    /// character and take the column alignment with it.
    func testAnEmojiTagDoesNotShortenItsColumn() {
        let entries = [entry("web-1", product: "\u{1F680}payments"),
                       entry("web-2", product: "search")]
        for line in FleetOutput.columns(entries).split(separator: "\n") {
            XCTAssertTrue(line.contains("example.com"))
        }
        XCTAssertTrue(FleetOutput.columns(entries).contains("\u{1F680}payments"))
    }

    func testPadNeverShortens() {
        XCTAssertEqual(FleetOutput.pad("abcdef", to: 3), "abcdef")
    }
}
