import Foundation

/// The fleet turned into something searchable: every host under the alias it is
/// actually reachable by, in the order the menu lists them.
///
/// Shared rather than duplicated. The panel and the `hangar` command answer the
/// same question, "which hosts match this", and mistake 18 was two things
/// answering one question differently.
public enum FleetIndex {

    /// The alias each host is reachable by, keyed by instance id.
    ///
    /// Hosts Hangar deliberately does not write still have a name, and it is the
    /// one ssh already resolves, so they keep their own rather than being shown
    /// under a slug that connects to nothing.
    public static func aliases(for instances: [Instance],
                               config: HangarConfig) -> [String: String] {
        let writer = SSHConfigWriter(config: config)
        var table: [String: String] = [:]
        table.reserveCapacity(instances.count)
        for entry in writer.entries(for: instances) {
            table[entry.instance.id] = entry.aliases.first
        }
        for instance in instances where !instance.isWrittenToSSHConfig {
            table[instance.id] = instance.aliasStem
        }
        return table
    }

    /// Search-ready entries, in menu order.
    public static func entries(for instances: [Instance],
                               config: HangarConfig) -> [SearchEntry] {
        let table = aliases(for: instances, config: config)
        return instances
            .map { SearchEntry(instance: $0, alias: table[$0.id] ?? $0.aliasStem) }
            .sorted { sortKey($0) < sortKey($1) }
    }

    /// Product, environment, alias, with anything carrying no product sent to the
    /// end rather than the front.
    ///
    /// An empty string sorts first, so an untagged group used to open the panel.
    /// That was survivable when untagged meant a handful of forgotten EC2 boxes.
    /// It is not now: a few git hosts in someone's ssh config would sit above
    /// their whole fleet, every time.
    public static func sortKey(_ entry: SearchEntry) -> (Int, String, String, String) {
        (entry.instance.product.isEmpty ? 1 : 0,
         entry.instance.product, entry.instance.env, entry.alias)
    }

    /// Matches for a query, best first, ties broken by alias so two runs of the
    /// same search list the same hosts in the same order.
    public static func ranked(_ entries: [SearchEntry],
                              matching query: Fuzzy.Query) -> [SearchEntry] {
        guard !query.isEmpty else { return entries }
        var scored: [(SearchEntry, Int)] = []
        scored.reserveCapacity(entries.count)
        for entry in entries {
            if let score = entry.score(for: query) { scored.append((entry, score)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.alias < $1.0.alias }
        return scored.map(\.0)
    }

    /// Entries whose host satisfies every clause. Clauses AND, including two on
    /// the same key, which the dictionary below cannot express because the
    /// second value silently replaces the first.
    public static func filtered(_ entries: [SearchEntry],
                                by filters: [HostFilter]) -> [SearchEntry] {
        guard !filters.isEmpty else { return entries }
        return entries.filter { entry in
            filters.allSatisfy { $0.matches(entry.instance) }
        }
    }

    /// Entries whose host satisfies a filter, e.g. `["env": "prod"]`. The same
    /// wildcard rules the hotkey filters use. Kept for the hotkeys, whose filters
    /// come from a config file written against exactly these rules.
    public static func filtered(_ entries: [SearchEntry],
                                by filter: [String: String]?) -> [SearchEntry] {
        guard let filter, !filter.isEmpty else { return entries }
        return entries.filter { entry in
            filter.allSatisfy { key, pattern in
                HangarConfig.wildcard(pattern, entry.instance.tagValue(for: key))
            }
        }
    }
}
