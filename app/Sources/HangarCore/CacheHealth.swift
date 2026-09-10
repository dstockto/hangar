import Foundation

/// How much the fleet on screen can be trusted, which is what the menubar glyph
/// is colouring. Kept out of the AppKit layer because it is a claim about the
/// cache's age, not about drawing.
public enum CacheHealth: Sendable, Equatable {
    /// A fetch is in flight. The cache underneath is whatever it was.
    case refreshing
    /// Refreshed inside the stale window.
    case fresh
    /// Past the stale window, still inside the healthy window.
    case aging
    /// Past the healthy window, or the last fetch failed.
    case stale
    /// Nothing has ever been cached, so there is no age to report. Distinct from
    /// `stale`, which is a claim that the fleet on screen is out of date; there
    /// is no fleet on screen to make that claim about.
    case unknown

    /// `staleAfterMinutes` and `healthyWithinHours` are clamped to at least one
    /// unit: a config of zero would otherwise report every cache stale the
    /// instant it was written.
    public static func classify(fetchedAt: Date?, now: Date = Date(),
                                isRefreshing: Bool, lastFetchFailed: Bool,
                                hasHosts: Bool,
                                staleAfterMinutes: Int,
                                healthyWithinHours: Int) -> CacheHealth {
        if isRefreshing { return .refreshing }
        guard let fetchedAt, hasHosts else { return .unknown }
        if lastFetchFailed { return .stale }
        let age = now.timeIntervalSince(fetchedAt)
        if age >= Double(max(1, healthyWithinHours)) * 3600 { return .stale }
        if age >= Double(max(1, staleAfterMinutes)) * 60 { return .aging }
        return .fresh
    }
}
