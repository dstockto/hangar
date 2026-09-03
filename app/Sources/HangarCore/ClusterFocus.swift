import Foundation

/// What the cluster is currently showing: a path down the same grouping levels
/// the menubar cascade uses, from the whole fleet to one host.
///
/// Pulled out of the view because "which hosts am I looking at" is a question
/// with a right answer, and a right answer deserves a test rather than a
/// synthetic click.
public struct ClusterFocus: Equatable, Sendable {
    /// One level that has been entered: which key in `group_by` it was, and the
    /// value chosen. The key travels with the value because levels get skipped.
    /// On a fleet where a third of the hosts carry `env_name`, some groups go
    /// straight from `env` to the hosts, and "the second thing in the path" is
    /// then no longer "the second key in `group_by`".
    public struct Step: Equatable, Sendable {
        public var level: Int
        public var key: String
        public var value: String

        public init(level: Int, key: String, value: String) {
            self.level = level
            self.key = key
            self.value = value
        }
    }

    /// One step per level entered so far. Empty is the whole fleet.
    public var path: [Step]
    /// Set when a single host has been opened, which is the last level down.
    public var hostID: String?

    public init(path: [Step] = [], hostID: String? = nil) {
        self.path = path
        self.hostID = hostID
    }

    public static let fleet = ClusterFocus()

    public var isFleet: Bool { path.isEmpty && hostID == nil }

    /// The level a click at this depth would open, or nil when the next click
    /// opens a host rather than another group.
    ///
    /// A key that no host in scope carries is skipped rather than drawn: it
    /// would put the whole group behind one "untagged" circle, which costs a
    /// click and says nothing. `FleetGrouping` applies the same rule to the
    /// menubar cascade, and the picture and the menu must not disagree about
    /// how deep the fleet goes.
    public func nextLevel(_ keys: [String],
                          among instances: [Instance]) -> (level: Int, key: String)? {
        var level = (path.last?.level ?? -1) + 1
        while level < keys.count {
            let key = keys[level]
            if instances.contains(where: { !$0.tagValue(for: key).isEmpty }) {
                return (level, key)
            }
            level += 1
        }
        return nil
    }

    public func matches(_ instance: Instance) -> Bool {
        if let hostID { return instance.id == hostID }
        return path.allSatisfy { instance.tagValue(for: $0.key) == $0.value }
    }

    public func filter(_ instances: [Instance]) -> [Instance] {
        instances.filter { matches($0) }
    }

    /// One level deeper.
    public func entering(level: Int, key: String, value: String) -> ClusterFocus {
        ClusterFocus(path: path + [Step(level: level, key: key, value: value)], hostID: nil)
    }

    public func opening(host id: String) -> ClusterFocus {
        ClusterFocus(path: path, hostID: id)
    }

    /// One level back out. From a host, back to the group it was in.
    public func leaving() -> ClusterFocus {
        if hostID != nil { return ClusterFocus(path: path, hostID: nil) }
        return ClusterFocus(path: Array(path.dropLast()), hostID: nil)
    }

    /// What the panels call the current scope. Empty for the whole fleet, which
    /// is the case where saying "the whole fleet" would be noise. An untagged
    /// group is named for what it is rather than shown as a gap.
    public var label: String {
        path.map { $0.value.isEmpty ? "untagged" : $0.value }.joined(separator: " · ")
    }

    /// The label of the level a step out lands on, so a control can name where
    /// back goes. Nil at the fleet, where there is nowhere further out, and
    /// empty when back is the whole fleet.
    public var backDestination: String? {
        isFleet ? nil : leaving().label
    }
}
