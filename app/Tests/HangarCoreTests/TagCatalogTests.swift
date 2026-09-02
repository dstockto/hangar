import XCTest
@testable import HangarCore

/// Whether an SRE whose fleet Hangar has never seen can make it work from the
/// setup screen, without editing JSON and without retagging anything.
final class TagCatalogTests: XCTestCase {

    /// A fleet using none of Hangar's default key names.
    private func foreignFleet() -> [Instance] {
        let units = ["risk", "trading", "clearing"]
        let tiers = ["prod", "uat", "dev"]
        let roles = ["api", "worker", "db"]
        return (0..<30).map { i in
            Fixture.instance([
                "BusinessUnit": units[i % units.count],
                "DeployTier": tiers[i % tiers.count],
                "Function": roles[i % roles.count],
                "CostCentre": "cc-\(1000 + i)",
                "Owner": "platform",
                "aws:autoscaling:groupName": "asg-\(i % 3)",
            ], id: "i-0\(String(format: "%015x", i))")
        }
    }

    func testDiscoversEveryRealKeyAndCountsIt() {
        let catalog = TagCatalog.discover(from: foreignFleet())
        XCTAssertEqual(catalog.fleetSize, 30)
        let names = catalog.keys.map(\.name)
        XCTAssertEqual(Set(names),
                       ["BusinessUnit", "DeployTier", "Function", "CostCentre", "Owner"])
        XCTAssertEqual(catalog.key(named: "BusinessUnit")?.instances, 30)
        XCTAssertEqual(catalog.key(named: "BusinessUnit")?.distinctValues, 3)
    }

    func testExcludesAWSManagedTags() {
        let catalog = TagCatalog.discover(from: foreignFleet())
        XCTAssertNil(catalog.key(named: "aws:autoscaling:groupName"),
                     "AWS-managed tags are not something to map")
    }

    func testSamplesLetAPersonRecogniseTheKey() throws {
        let catalog = TagCatalog.discover(from: foreignFleet())
        let unit = try XCTUnwrap(catalog.key(named: "BusinessUnit"))
        XCTAssertEqual(unit.samples, ["clearing", "risk", "trading"])
    }

    func testAnIdentifierLikeKeyScoresBelowAGroupingKey() throws {
        let catalog = TagCatalog.discover(from: foreignFleet())
        let grouping = try XCTUnwrap(catalog.key(named: "DeployTier"))
        let identifier = try XCTUnwrap(catalog.key(named: "CostCentre"))
        let single = try XCTUnwrap(catalog.key(named: "Owner"))
        XCTAssertGreaterThan(grouping.groupingScore(fleetSize: 30),
                             identifier.groupingScore(fleetSize: 30),
                             "30 distinct values is an id, not a group")
        XCTAssertEqual(single.groupingScore(fleetSize: 30), 0,
                       "one value groups nothing")
    }

    func testSuggestionsAreOfferedOnlyWhenTheNameLooksRelated() {
        let catalog = TagCatalog.discover(from: foreignFleet())
        // "DeployTier" contains "tier", "Function" contains "function".
        XCTAssertEqual(catalog.suggestion(for: .env), "DeployTier")
        XCTAssertEqual(catalog.suggestion(for: .role), "Function")
        // Nothing in this fleet reads as a product or a hostname, and a wrong
        // suggestion is worse than an empty picker.
        XCTAssertNil(catalog.suggestion(for: .product))
        XCTAssertNil(catalog.suggestion(for: .hostname))
    }

    // MARK: - Choosing a key from the setup screen

    func testWhatTheDefaultsAlreadyCoverAndWhatTheyDoNot() {
        // Worth stating precisely, because it is the case for the picker. The
        // defaults catch "Function" as a role, so this fleet is not *ungrouped*,
        // but the two groupings that build the menu resolve to nothing.
        let mapping = TagMapping.standard
        let normalized = mapping.normalize(foreignFleet()[0])
        XCTAssertEqual(normalized.role, "api", "the defaults do catch Function")
        XCTAssertEqual(normalized.product, "", "BusinessUnit is not a name we guess")
        XCTAssertEqual(normalized.env, "", "nor DeployTier")
        XCTAssertEqual(normalized.aliasStem, "api",
                       "so every host in a tier collapses to its role")
    }

    func testChoosingAKeyMakesTheFleetGroupImmediately() {
        let fleet = foreignFleet()
        var mapping = TagMapping.standard
        mapping.use("BusinessUnit", for: .product)
        mapping.use("DeployTier", for: .env)
        mapping.use("Function", for: .role)

        let normalized = mapping.normalize(fleet)
        XCTAssertFalse(TagMapping.isUngrouped(normalized[0]))
        XCTAssertEqual(normalized[0].product, "risk")
        XCTAssertEqual(normalized[0].env, "prod")
        XCTAssertEqual(normalized[0].role, "api")
        XCTAssertEqual(normalized[0].aliasStem, "risk-prod-api")
    }

    func testChoosingAKeyKeepsTheDefaultsBehindIt() {
        var mapping = TagMapping.standard
        mapping.use("BusinessUnit", for: .product)
        XCTAssertEqual(mapping.product.first, "BusinessUnit", "the choice wins")
        XCTAssertTrue(mapping.product.contains("Service"),
                      "and the defaults still resolve a fleet that is not consistent")
        XCTAssertFalse(mapping.product.dropFirst().contains("BusinessUnit"),
                       "without duplicating the choice")
    }

    func testNotUsedMeansNothingResolves() {
        var mapping = TagMapping.standard
        mapping.use(nil, for: .env)
        XCTAssertTrue(mapping.env.isEmpty)
        let instance = mapping.normalize(
            Fixture.instance(["Environment": "prod", "Name": "web"]))
        XCTAssertEqual(instance.env, "", "the idea is deliberately unmapped")
        XCTAssertEqual(instance.aliasStem, "web", "and the alias drops it")
    }

    func testThePickerOpensShowingWhatIsActuallyInEffect() {
        let fleet = [Fixture.instance(["Service": "payments", "Environment": "prod",
                                       "Name": "web"])]
        let catalog = TagCatalog.discover(from: fleet)
        let mapping = TagMapping.standard
        XCTAssertEqual(mapping.resolvedKey(for: .product, in: catalog), "Service")
        XCTAssertEqual(mapping.resolvedKey(for: .env, in: catalog), "Environment")
        XCTAssertEqual(mapping.resolvedKey(for: .role, in: catalog), "Name")
        XCTAssertNil(mapping.resolvedKey(for: .hostname, in: catalog),
                     "this fleet has no hostname tag, so the picker shows nothing")
    }

    func testResolutionIsCaseInsensitiveAgainstTheRealKeyName() {
        let catalog = TagCatalog.discover(from: [Fixture.instance(["ENVIRONMENT": "prod"])])
        // The picker must offer the key as AWS spells it, not as we guessed.
        XCTAssertEqual(TagMapping.standard.resolvedKey(for: .env, in: catalog),
                       "ENVIRONMENT")
    }

    func testAnEmptyFleetProducesAnEmptyCatalog() {
        XCTAssertTrue(TagCatalog.discover(from: []).isEmpty)
        XCTAssertNil(TagCatalog.empty.suggestion(for: .product))
    }

    func testCatalogSurvivesTheCacheRoundTrip() throws {
        let catalog = TagCatalog.discover(from: foreignFleet())
        let decoded = try JSONDecoder().decode(
            TagCatalog.self, from: try JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
    }

    func testTheWholeFlowForAFleetHangarHasNeverSeen() {
        // What an SRE does on first launch: fetch, see nothing grouped, pick
        // three keys from the picker, get working aliases.
        let fleet = foreignFleet()
        let catalog = TagCatalog.discover(from: fleet)
        var config = HangarConfig.standard()
        var mapping = config.tagMapping

        for (concept, chosen) in [(TagCatalog.Concept.product, "BusinessUnit"),
                                  (.env, "DeployTier"),
                                  (.role, "Function")] {
            XCTAssertNotNil(catalog.key(named: chosen), "the picker offers \(chosen)")
            mapping.use(chosen, for: concept)
        }
        config.tags = mapping

        let entries = SSHConfigWriter(config: config)
            .entries(for: mapping.normalize(fleet))
        XCTAssertEqual(entries.count, 30)
        let aliases = Set(entries.map { $0.aliases[0] })
        // Collisions are numbered, so match the stem rather than an exact alias.
        XCTAssertTrue(aliases.contains { $0.hasPrefix("risk-prod-api") },
                      "got \(aliases.sorted().prefix(4))")
        XCTAssertFalse(aliases.contains { $0.hasPrefix("i-0") },
                       "no host should still be named by its instance id")
        XCTAssertTrue(aliases.allSatisfy { $0.contains("-") },
                      "every alias carries its grouping")
    }
}
