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

    /// Roughly how much machine this is, on a scale where `large` is 4. Taken
    /// from the size suffix alone, which is the only thing DescribeInstances
    /// tells us without asking a second API what a type actually contains.
    /// Relative, not exact: it exists so a picture can show that one host is
    /// bigger than another, not to price anything.
    public var sizeWeight: Double {
        switch size {
        case "nano":    return 0.25
        case "micro":   return 0.5
        case "small":   return 1
        case "medium":  return 2
        case "large":   return 4
        case "xlarge":  return 8
        // A bare-metal instance is the whole host, which across families lands
        // around a 24xlarge. Approximate on purpose: the suffix is all
        // DescribeInstances gives us.
        case "metal":   return 192
        default: break
        }
        // 2xlarge, 4xlarge, 12xlarge and so on: the multiple times an xlarge.
        if size.hasSuffix("xlarge"),
           let multiple = Double(size.dropLast("xlarge".count)) {
            return multiple * 8
        }
        // Unknown sizes sit between medium and large rather than at either end,
        // so an unfamiliar family neither dominates the picture nor vanishes.
        return 3
    }

    /// The size in two or three characters, for drawing inside a small circle:
    /// `4xl`, `lg`, `md`. Empty when the string is not shaped like a type, so a
    /// caller can fall back rather than print nonsense.
    public var shortSize: String {
        switch size {
        case "nano":   return "nano"
        case "micro":  return "mic"
        case "small":  return "sm"
        case "medium": return "md"
        case "large":  return "lg"
        case "xlarge": return "xl"
        case "metal":  return "metal"
        default: break
        }
        // "8xlarge" is "8xl", not "8xxl": drop the whole suffix, not just the
        // "large" part of it.
        if size.hasSuffix("xlarge") { return size.dropLast("xlarge".count) + "xl" }
        return size.isEmpty ? "" : String(size.prefix(4))
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
