import Foundation

/// Which hue a group name gets in the cluster, in degrees on the colour wheel.
///
/// Confined to one arc on purpose. Red, amber and green belong to instance
/// state, and a product circle drawn in the terminated red reads as a fleet on
/// fire rather than as a category. Here rather than in the AppKit layer because
/// "does this collide with a state colour" is a question with a right answer.
public enum CategoryHue {
    /// The arc categories are drawn from: teal, through blue and violet, to
    /// magenta. Wide enough for ten separable steps and clear of every state.
    public static let arc: ClosedRange<Double> = 178...330

    /// What state owns, plus the guard band that keeps a category from being
    /// mistaken for one at the size these circles are drawn. Amber sits at 40,
    /// running green at 150, and terminated red at 354, which wraps.
    public static let reserved: [ClosedRange<Double>] = [
        22...58, 132...168, 336...360, 0...12,
    ]

    /// Ten steps: distinct enough to tell apart, few enough that two products
    /// never land a degree from each other.
    public static let slots = 10

    /// Stable per name, so the same fleet is the same picture every launch.
    public static func degrees(for name: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let slot = Double(hash % UInt64(slots))
        return arc.lowerBound + slot * (arc.upperBound - arc.lowerBound) / Double(slots)
    }

    public static func isReserved(_ degrees: Double) -> Bool {
        reserved.contains { $0.contains(degrees) }
    }
}
