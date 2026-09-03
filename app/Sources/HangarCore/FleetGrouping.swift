import Foundation

/// How the fleet is arranged in the menubar cascade.
///
/// Hangar offers three grouping levels, and most fleets use fewer. One is
/// perfectly reasonable: a fleet tagged only by team, or only by service, has
/// nothing to put on a second level. Earlier this produced a menu with a level
/// containing a single "untagged" entry containing everything, which is a level
/// that costs a click and carries no information.
///
/// So a level exists only if some host actually has a value for it. Kept out of
/// the UI layer so the shape of the menu can be asserted rather than eyeballed.
public enum FleetGrouping {
    public indirect enum Node: Sendable, Equatable {
        case group(title: String, children: [Node])
        case host(Instance)
    }

    /// The default levels, widest first, expressed as the canonical keys so a
    /// fleet that has been mapped groups the way it always did.
    public static let defaultLevels = [TagMapping.Canonical.product,
                                       TagMapping.Canonical.env,
                                       TagMapping.Canonical.envName]

    /// One submenu level per key, in order. Any tag key works, not only the ones
    /// Hangar maps: a fleet that wants Team then Environment says so and gets
    /// exactly that. `tagValue(for:)` resolves the canonical names and falls
    /// back to the instance's own tags, so both spellings work here.
    public static func tree(_ instances: [Instance],
                            groupBy keys: [String] = defaultLevels) -> [Node] {
        build(instances, keys: keys, depth: 0)
    }

    private static func build(_ instances: [Instance], keys: [String],
                              depth: Int) -> [Node] {
        guard depth < keys.count else { return leaves(instances) }
        let key = keys[depth]
        let value: (Instance) -> String = { $0.tagValue(for: key) }

        // A level nobody uses is not a level. Skip straight past it rather than
        // inventing a group to hold the whole fleet.
        guard instances.contains(where: { !value($0).isEmpty }) else {
            return build(instances, keys: keys, depth: depth + 1)
        }

        let grouped = Dictionary(grouping: instances) { value($0).isEmpty ? "untagged" : value($0) }
        // One group holding everything adds a click and says nothing.
        if grouped.count == 1, let only = grouped.first, only.key == "untagged" {
            return build(instances, keys: keys, depth: depth + 1)
        }
        return grouped.keys.sorted().map { title in
            .group(title: title,
                   children: build(grouped[title] ?? [], keys: keys, depth: depth + 1))
        }
    }

    private static func leaves(_ instances: [Instance]) -> [Node] {
        instances
            .sorted { ($0.aliasStem, $0.id) < ($1.aliasStem, $1.id) }
            .map { .host($0) }
    }

    /// What one level actually does at its place in the cascade.
    ///
    /// A key is not good or bad on its own, only in a position. `env_name` looks
    /// fine on a fleet where a third of the hosts carry one, and is a poor third
    /// level on that same fleet, because under product and environment most
    /// groups have nobody carrying it and gain a level holding one "untagged"
    /// entry. That is knowable before anyone clicks it, and this is how.
    public struct LevelReport: Sendable, Equatable {
        public var key: String
        /// Groups this level creates, summed over every scope it appears in.
        public var groups: Int
        /// Hosts reaching this level with no value for its key: either their
        /// whole scope skipped it, or they landed in its untagged group.
        public var withoutValue: Int
        /// Hosts that reach this level at all.
        public var hosts: Int

        public init(key: String, groups: Int = 0, withoutValue: Int = 0, hosts: Int = 0) {
            self.key = key
            self.groups = groups
            self.withoutValue = withoutValue
            self.hosts = hosts
        }

        /// True when the level does nothing for most of the hosts that reach it.
        public var isMostlyEmpty: Bool {
            hosts > 0 && withoutValue * 2 > hosts
        }
    }

    /// One report per configured level, walking the same tree `tree` builds.
    public static func report(_ instances: [Instance],
                              groupBy keys: [String] = defaultLevels) -> [LevelReport] {
        var reports = keys.map { LevelReport(key: $0) }

        func walk(_ scope: [Instance], depth: Int) {
            guard depth < keys.count, !scope.isEmpty else { return }
            let key = keys[depth]
            let value: (Instance) -> String = { $0.tagValue(for: key) }
            reports[depth].hosts += scope.count

            // Skipped for this scope: nobody here carries it, so the level is
            // not drawn and every host passes through to the next one.
            guard scope.contains(where: { !value($0).isEmpty }) else {
                reports[depth].withoutValue += scope.count
                walk(scope, depth: depth + 1)
                return
            }
            let grouped = Dictionary(grouping: scope) { value($0) }
            reports[depth].groups += grouped.count
            reports[depth].withoutValue += grouped[""]?.count ?? 0
            for members in grouped.values { walk(members, depth: depth + 1) }
        }

        walk(instances, depth: 0)
        return reports
    }

    /// What appending `key` to the current levels would do, without committing
    /// to it. The question someone actually has in front of the Add menu.
    public static func reportAppending(_ key: String, to keys: [String],
                                       in instances: [Instance]) -> LevelReport {
        report(instances, groupBy: keys + [key]).last ?? LevelReport(key: key)
    }

    /// How many levels this fleet actually produces, which is not the same as
    /// how many were configured: a key nothing carries adds no level.
    public static func depth(_ instances: [Instance],
                             groupBy keys: [String] = defaultLevels) -> Int {
        keys.count { key in instances.contains { !$0.tagValue(for: key).isEmpty } }
    }
}
