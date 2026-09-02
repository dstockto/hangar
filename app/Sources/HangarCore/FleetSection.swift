import Foundation

/// What the menu's host section should show. Pulled out of the menu because the
/// decision is not about AppKit: "no hosts found" is a claim about the AWS
/// account, and it must not be made by a Hangar that has never reached AWS.
public enum FleetSection: Sendable, Equatable {
    /// There are hosts; draw the cascade.
    case hosts
    /// A first fetch is in flight and there is nothing cached yet.
    case looking
    /// Nothing has ever been fetched, and nothing is being fetched now.
    case neverFetched
    /// AWS was reached and returned no instances Hangar can use.
    case empty
    /// Say nothing: the fetch failed before anything was ever cached, and the
    /// error row above already explains why, with a Retry next to it.
    case hidden

    /// `everReachedAWS` is the whole point: it separates an empty account from
    /// an unreachable one, which are different problems with different fixes.
    public static func classify(hostCount: Int, isRefreshing: Bool,
                                lastFetchFailed: Bool,
                                everReachedAWS: Bool) -> FleetSection {
        if hostCount > 0 { return .hosts }
        if everReachedAWS { return .empty }
        if lastFetchFailed { return .hidden }
        return isRefreshing ? .looking : .neverFetched
    }
}
