import Foundation

/// What the cluster is currently showing: a path down the same grouping levels
/// the menubar cascade uses, from the whole fleet to one host.
///
/// Pulled out of the view because "which hosts am I looking at" is a question
/// with a right answer, and a right answer deserves a test rather than a
/// synthetic click.
public struct ClusterFocus: Equatable, Sendable {
    /// One value per grouping level entered so far. Empty is the whole fleet.
    public var path: [String]
    /// Set when a single host has been opened, which is the last level down.
    public var hostID: String?

    public init(path: [String] = [], hostID: String? = nil) {
        self.path = path
        self.hostID = hostID
    }

    public static let fleet = ClusterFocus()

    public var isFleet: Bool { path.isEmpty && hostID == nil }

    /// The level a click at this depth would open, or nil when the next click
    /// opens a host rather than another group.
    public func nextKey(_ keys: [String]) -> String? {
        path.count < keys.count ? keys[path.count] : nil
    }

    public func matches(_ instance: Instance, groupingKeys keys: [String]) -> Bool {
        if let hostID { return instance.id == hostID }
        for (level, value) in path.enumerated() {
            guard level < keys.count else { return true }
            guard instance.tagValue(for: keys[level]) == value else { return false }
        }
        return true
    }

    public func filter(_ instances: [Instance], groupingKeys keys: [String]) -> [Instance] {
        instances.filter { matches($0, groupingKeys: keys) }
    }

    /// One level deeper.
    public func entering(_ value: String) -> ClusterFocus {
        ClusterFocus(path: path + [value], hostID: nil)
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
    /// is the case where saying "the whole fleet" would be noise.
    public var label: String {
        path.joined(separator: " · ")
    }
}
