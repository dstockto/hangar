import Foundation

/// Which result is selected after the results change.
///
/// The top hit, so Return connects without touching the arrow keys. A host the
/// user picked themselves survives the next keystroke; one the panel picked for
/// them does not, or an auto-selection made three characters ago ends up sitting
/// mid-list while the best match for what they finished typing goes unselected.
public struct PanelSelection: Equatable, Sendable {
    /// Index into the host ids handed in, never a header row.
    public let index: Int
    /// True when this is the user's own selection carried across the change,
    /// which is also the answer to whether the next change should carry it again.
    public let carried: Bool

    public init(index: Int, carried: Bool) {
        self.index = index
        self.carried = carried
    }

    public static func next(ids: [String], previous: String?,
                            chosen: Bool) -> PanelSelection? {
        if chosen, let previous, let kept = ids.firstIndex(of: previous) {
            return PanelSelection(index: kept, carried: true)
        }
        return ids.isEmpty ? nil : PanelSelection(index: 0, carried: false)
    }
}
