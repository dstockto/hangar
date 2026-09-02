import Foundation

/// What an EC2 instance type string says about itself.
///
/// `m6i.large` is a family, a generation, an attribute suffix and a size, and
/// all of it is readable without asking AWS anything. Nothing here is advice:
/// Hangar does not know why a `t3.micro` is in production.
public struct InstanceType: Sendable, Equatable {
    public var raw: String
    /// `m6i` from `m6i.large`.
    public var family: String
    /// The series letter, `m`, `c`, `r`, `t`, and so on.
    public var series: String
    /// The generation digit, 6 in `m6i`. Nil when the string is not shaped like
    /// an instance type at all.
    public var generation: Int?
    /// `large` from `m6i.large`.
    public var size: String

    /// The `t` series, which bills for a baseline and throttles above it.
    public var isBurstable: Bool { series == "t" }

    /// The families AWS itself lists as previous generation. A table rather than
    /// arithmetic on the generation digit, because `m6i` beside an `m7i` is not
    /// a finding: AWS still sells it, and calling it out would bury the `m4`
    /// that actually matters under noise.
    static let previousGenerationFamilies: Set<String> = [
        "t1", "m1", "m2", "m3", "m4", "c1", "c3", "c4", "cc2", "cg1", "cr1",
        "r3", "i2", "hi1", "hs1", "g2", "d2", "m5", "t2",
    ]

    /// One of the families AWS has moved to previous generation.
    public var isPreviousGeneration: Bool {
        InstanceType.previousGenerationFamilies.contains(family)
    }

    public init(_ raw: String) {
        self.raw = raw
        let halves = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        self.family = halves.first.map(String.init) ?? raw
        self.size = halves.count > 1 ? String(halves[1]) : ""
        self.series = String(family.prefix { $0.isLetter && !$0.isNumber }.prefix(1))
        let digits = family.drop { !$0.isNumber }.prefix { $0.isNumber }
        self.generation = Int(digits)
    }
}
