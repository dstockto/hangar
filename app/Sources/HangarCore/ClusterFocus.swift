import Foundation

/// What the cluster is currently showing: the whole fleet, or one group opened
/// up. Pulled out of the view because "which hosts am I looking at" is a
/// question with a right answer, and a right answer deserves a test rather than
/// a synthetic click.
public enum ClusterFocus: Equatable, Sendable {
    case fleet
    case group(product: String, env: String?)

    /// The grouping keys are the menu's, not a guess: a fleet grouped by Team
    /// and Tier drills on Team and Tier.
    public func matches(_ instance: Instance, groupingKeys keys: [String]) -> Bool {
        guard case .group(let product, let env) = self else { return true }
        let productKey = keys.first ?? TagMapping.Canonical.product
        let envKey = keys.count > 1 ? keys[1] : TagMapping.Canonical.env
        guard instance.tagValue(for: productKey) == product else { return false }
        guard let env else { return true }
        return instance.tagValue(for: envKey) == env
    }

    public func filter(_ instances: [Instance], groupingKeys keys: [String]) -> [Instance] {
        instances.filter { matches($0, groupingKeys: keys) }
    }

    /// What the panels call the current scope. Empty for the whole fleet, which
    /// is the case where saying "the whole fleet" would be noise.
    public var label: String {
        switch self {
        case .fleet: return ""
        case .group(let product, let env):
            return env.map { "\(product) · \($0)" } ?? product
        }
    }
}
