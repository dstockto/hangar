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

/// The values one tag key takes, which is what `hangar values env` answers.
final class TagValueCountTests: XCTestCase {

    private let fleet = [
        Fixture.instance(["env": "prod", "team": "platform"]),
        Fixture.instance(["env": "prod", "team": "search"]),
        Fixture.instance(["env": "prod"]),
        Fixture.instance(["env": "qa", "team": "platform"]),
        Fixture.instance([:]),
    ]

    func testCountsPerValueMostUsedFirst() {
        XCTAssertEqual(TagCatalog.values(of: "env", in: fleet),
                       [TagCatalog.ValueCount(value: "prod", hosts: 3),
                        TagCatalog.ValueCount(value: "qa", hosts: 1)])
    }

    /// A host that does not carry the key is not a host carrying an empty value.
    func testHostsWithoutTheKeyAreNotCounted() {
        let total = TagCatalog.values(of: "team", in: fleet).reduce(0) { $0 + $1.hosts }
        XCTAssertEqual(total, 3)
    }

    /// Equal counts sort by name, so two runs list the same values in the same
    /// order.
    func testTiesBreakByValue() {
        XCTAssertEqual(TagCatalog.values(of: "team", in: fleet).map(\.value),
                       ["platform", "search"])
    }

    /// Read through the same lookup `-f` uses, so what this lists is what a
    /// filter will match. `state` is not a tag and still has values.
    func testFriendlyKeysAreCountedToo() {
        let states = TagCatalog.values(of: "state", in: fleet)
        XCTAssertEqual(states, [TagCatalog.ValueCount(value: "running", hosts: 5)])
    }

    func testAKeyNobodyCarriesHasNoValues() {
        XCTAssertTrue(TagCatalog.values(of: "nosuchkey", in: fleet).isEmpty)
    }

    func testAnEmptyFleetHasNoValues() {
        XCTAssertTrue(TagCatalog.values(of: "env", in: []).isEmpty)
    }
}

/// Which key names a filter resolves rather than reading, and the fact that
/// `hangar tags` has to read the fleet's own tags to avoid inventing rows.
final class ResolvedKeyNameTests: XCTestCase {

    /// Every name in the list is genuinely intercepted. The list and the switch
    /// in `tagValue(for:)` are two halves of one fact, so this pins them together
    /// rather than trusting that both were edited.
    ///
    /// Probed through a differently-cased spelling, because for `env`, `product`
    /// and `env_name` the canonical key *is* the tag key, so the interception
    /// only shows as case folding. `ENV` reaching `tags["env"]` rather than
    /// `tags["ENV"]` is the same interception that sends `Role` to `tags["Name"]`.
    func testEveryResolvedNameIsActuallyIntercepted() {
        let instance = Fixture.instance(["Name": "resolved-role", "env": "resolved-env",
                                         "env_name": "resolved-envname",
                                         "product": "resolved-product"])
        for name in Instance.resolvedKeyNames {
            var shadowing = instance
            let shouted = name.uppercased()
            shadowing.tags[shouted] = "RAW-\(name)"
            XCTAssertNotEqual(shadowing.tagValue(for: shouted), "RAW-\(name)",
                              "'\(name)' is listed as resolved and reads the tag")
        }
    }

    /// The other half: a key outside the list is read straight off the instance,
    /// which is what makes filtering on a fleet's own vocabulary work at all.
    func testAKeyOutsideTheListIsReadFromTheTags() {
        var instance = Fixture.instance([:])
        instance.tags["cost-centre"] = "4021"
        XCTAssertEqual(instance.tagValue(for: "cost-centre"), "4021")
        XCTAssertFalse(Instance.resolvedKeyNames.contains("cost-centre"))
    }

    /// The list is lowercase and `tagValue` folds case before consulting it, so
    /// a fleet's `Role` and `STATE` reach the same branch as `role` and `state`.
    func testTheListIsMatchedWithoutRegardToCase() {
        for shouted in ["Role", "STATE", "Instance_Id"] {
            XCTAssertTrue(Instance.resolvedKeyNames.contains(shouted.lowercased()))
        }
        for own in ["team", "cost-centre"] {
            XCTAssertFalse(Instance.resolvedKeyNames.contains(own))
        }
    }

    /// Discovering from a normalized fleet listed every grouping key twice,
    /// because normalize writes the canonical key and keeps the original.
    func testDiscoverOnRawTagsDoesNotInventCanonicalRows() {
        let raw = [Fixture.instance(["Environment": "prod", "Service": "checkout"]),
                   Fixture.instance(["Environment": "qa", "Service": "checkout"])]
        let names = TagCatalog.discover(from: raw).keys.map(\.name)
        XCTAssertEqual(Set(names), ["Environment", "Service"])

        // What the normalized fleet would have produced, for contrast.
        let normalized = TagMapping.standard.normalize(raw)
        let doubled = TagCatalog.discover(from: normalized).keys.map(\.name)
        XCTAssertTrue(Set(doubled).isSuperset(of: ["Environment", "env"]))
    }
}

/// Which keys a filter genuinely answers differently from the tag.
///
/// Asked of the fleet, not of a list of names. The list cannot answer it: four
/// of the nine names are first in their own candidate list, so they resolve to
/// the tag they look like and filter perfectly.
final class ShadowedKeyTests: XCTestCase {

    private func shadowed(_ raw: [Instance],
                          _ mapping: TagMapping = .standard) -> Set<String> {
        let keys = TagCatalog.discover(from: raw).keys.map(\.name)
        return TagCatalog.shadowedKeys(among: keys, raw: raw,
                                       resolved: mapping.normalize(raw))
    }

    /// The regression. A fleet spelling everything canonically has nothing
    /// shadowed, and the old marker named `env` and `product` here, which are
    /// the two keys the README filters on throughout.
    func testACanonicallyTaggedFleetShadowsNothing() {
        let fleet = [Fixture.instance(["env": "prod", "product": "checkout",
                                       "team": "platform", "cost-centre": "4021"])]
        XCTAssertEqual(shadowed(fleet), [])
    }

    /// And those keys really do filter, which is the fact the marker was denying.
    func testTheKeysItNoLongerMarksActuallyFilter() {
        let host = TagMapping.standard.normalize(
            Fixture.instance(["env": "prod", "product": "checkout"]))
        XCTAssertEqual(host.tagValue(for: "env"), "prod")
        XCTAssertEqual(host.tagValue(for: "product"), "checkout")
    }

    /// A fleet carrying both `Name` and its own `role`: `Name` wins the role
    /// candidates, so `-f role=` answers with the Name value and the role tag is
    /// unreachable. `Name` itself is not shadowed, because it reads its own tag.
    func testARealCollisionIsMarked() {
        let fleet = [Fixture.instance(["Name": "web-1", "role": "web"])]
        XCTAssertEqual(shadowed(fleet), ["role"])
    }

    /// Caught by comparing answers and missed by any list of names: a config that
    /// puts `Name` first in the product candidates shadows `product`.
    func testACustomMappingCanShadowAKeyTheListWouldClear() {
        var mapping = TagMapping.standard
        mapping.product = ["Name"] + mapping.product
        let fleet = [Fixture.instance(["Name": "web-1", "product": "checkout"])]
        XCTAssertEqual(shadowed(fleet, mapping), ["product"])
        // The same fleet under the stock mapping shadows nothing.
        XCTAssertEqual(shadowed(fleet), [])
    }

    /// A key outside the nine can be shadowed too, which is why the marker does
    /// not consult the list. `hostname` is not in it.
    func testAKeyOutsideTheResolvedListCanBeShadowed() {
        var mapping = TagMapping.standard
        mapping.hostname = ["fqdn"] + mapping.hostname
        let fleet = [Fixture.instance(["hostname": "a.example.com",
                                       "fqdn": "b.example.com"])]
        XCTAssertTrue(shadowed(fleet, mapping).contains("hostname"))
        XCTAssertFalse(Instance.resolvedKeyNames.contains("hostname"))
    }

    func testAnEmptyFleetShadowsNothing() {
        XCTAssertEqual(TagCatalog.shadowedKeys(among: ["env"], raw: [], resolved: []), [])
    }
}
