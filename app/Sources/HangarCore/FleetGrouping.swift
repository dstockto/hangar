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

    /// How many levels this fleet actually produces, which is not the same as
    /// how many were configured: a key nothing carries adds no level.
    public static func depth(_ instances: [Instance],
                             groupBy keys: [String] = defaultLevels) -> Int {
        keys.count { key in instances.contains { !$0.tagValue(for: key).isEmpty } }
    }
}
