import Foundation

/// What the fleet says about itself, from the response Hangar already has.
///
/// Every number here comes out of one `ec2:DescribeInstances`. Nothing in this
/// file may need another call or another permission: "one read-only AWS call" is
/// a promise on the landing page, and an insight that quietly breaks it is worth
/// less than the promise.
public struct FleetInsights: Sendable, Equatable {

    /// Hosts Hangar itself serves badly, which is the half of this the user can
    /// act on today by fixing a tag.
    public struct Hygiene: Sendable, Equatable {
        public var missingProduct: Int = 0
        public var missingEnv: Int = 0
        public var missingName: Int = 0
        /// Reachable only by private address, because no hostname tag was found.
        public var missingHostname: Int = 0
        /// Names two or more hosts share, with how many share them. Not a
        /// fault: `SSHConfigWriter` numbers them `-1`, `-2` by launch time and
        /// gives each an id-suffixed alias as well, so ssh always reaches the
        /// host you asked for. It is worth knowing because those numbers move
        /// when an instance is replaced, and the id alias is the stable one.
        public var sharedNames: [String: Int] = [:]

        /// Shared names are deliberately not part of this: they are handled,
        /// and counting them as dirt made a well-tagged fleet look broken.
        public var isClean: Bool {
            missingProduct == 0 && missingEnv == 0 && missingName == 0
                && missingHostname == 0
        }

        /// What actually wants attention, for the panel's headline.
        public var problems: Int {
            [missingProduct, missingEnv, missingName, missingHostname]
                .filter { $0 > 0 }.count
        }
    }

    public struct GroupPlacement: Sendable, Equatable {
        public var product: String
        public var env: String
        public var count: Int
        public var zones: [String]
        public var inAutoscalingGroup: Int

        /// One zone and more than one host. A single host cannot be spread, so
        /// calling it single-zone would be a finding about arithmetic.
        public var isSingleZone: Bool { count > 1 && zones.count == 1 }
        public var pets: Int { count - inAutoscalingGroup }
    }

    public struct AgeBucket: Sendable, Equatable {
        public var label: String
        public var count: Int
    }

    public struct FamilyUse: Sendable, Equatable {
        public var family: String
        public var count: Int
        public var isBurstable: Bool
        public var isPreviousGeneration: Bool
    }

    public struct ExposureByEnv: Sendable, Equatable {
        public var env: String
        public var withPublicAddress: Int
        public var total: Int
    }

    public var total: Int = 0
    public var running: Int = 0
    public var stopped: Int = 0
    /// Hosts `DescribeInstances` actually described. Placement, ages, families
    /// and exposure are computed over these alone.
    ///
    /// A host imported from an ssh config or a CSV has no availability zone, no
    /// instance type and no launch time, and counting it as "not spread" or "no
    /// public address" would be an answer to a question nobody asked. Mistake 18
    /// was two things answering the same question differently; this is the same
    /// shape, so the denominator travels with the number.
    public var described: Int = 0
    public var undescribed: Int { max(0, total - described) }

    /// What the placement, age, family and exposure panels are counting, in the
    /// words those panels should print.
    public var coverage: String? {
        guard undescribed > 0 else { return nil }
        return described == 0
            ? "no EC2 data for any of these \(total) hosts"
            : "\(described) of \(total) hosts; the rest came from a source that "
                + "does not describe them"
    }
    public var hygiene = Hygiene()
    public var placement: [GroupPlacement] = []
    public var ages: [AgeBucket] = []
    public var families: [FamilyUse] = []
    public var exposure: [ExposureByEnv] = []

    /// Buckets, widest last. The labels are the copy the panel shows.
    static let ageBuckets: [(label: String, upperDays: Double?)] = [
        ("under a day", 1), ("under a week", 7), ("under a month", 30),
        ("under 90 days", 90), ("under 180 days", 180), ("over 180 days", nil),
    ]

    public static func compute(_ instances: [Instance],
                               now: Date = Date()) -> FleetInsights {
        var insights = FleetInsights()
        insights.total = instances.count
        insights.running = instances.count { $0.state == "running" }
        insights.stopped = instances.count { $0.state == "stopped" }

        var aliasCounts: [String: Int] = [:]
        var groups: [String: GroupPlacement] = [:]
        var zoneSets: [String: Set<String>] = [:]
        var ageCounts = [Int](repeating: 0, count: FleetInsights.ageBuckets.count)
        var unknownAge = 0
        var familyCounts: [String: Int] = [:]
        var exposureCounts: [String: (withPublic: Int, total: Int)] = [:]

        for instance in instances {
            // Tag hygiene applies to every host: a missing name is Hangar serving
            // it badly whatever it came from.
            if instance.product.isEmpty { insights.hygiene.missingProduct += 1 }
            if instance.env.isEmpty { insights.hygiene.missingEnv += 1 }
            if instance.role.isEmpty { insights.hygiene.missingName += 1 }
            if (instance.tags["hostname"] ?? "").isEmpty {
                insights.hygiene.missingHostname += 1
            }
            aliasCounts[instance.aliasStem, default: 0] += 1

            // Everything below needs fields only DescribeInstances returns.
            guard instance.origin == .ec2 else { continue }
            insights.described += 1

            let key = "\(instance.product)\u{0}\(instance.env)"
            var group = groups[key] ?? GroupPlacement(
                product: instance.product.isEmpty ? "untagged" : instance.product,
                env: instance.env.isEmpty ? "untagged" : instance.env,
                count: 0, zones: [], inAutoscalingGroup: 0)
            group.count += 1
            if instance.isASG { group.inAutoscalingGroup += 1 }
            groups[key] = group
            if let zone = instance.availabilityZone, !zone.isEmpty {
                zoneSets[key, default: []].insert(zone)
            }

            if let index = ageIndex(of: instance, now: now) {
                ageCounts[index] += 1
            } else {
                unknownAge += 1
            }

            familyCounts[InstanceType(instance.type).family, default: 0] += 1

            let env = instance.env.isEmpty ? "untagged" : instance.env
            var exposure = exposureCounts[env] ?? (0, 0)
            exposure.total += 1
            if let public_ = instance.publicIP, !public_.isEmpty { exposure.withPublic += 1 }
            exposureCounts[env] = exposure
        }

        insights.hygiene.sharedNames = aliasCounts.filter { $0.value > 1 }

        insights.placement = groups.map { key, group in
            var resolved = group
            resolved.zones = (zoneSets[key] ?? []).sorted()
            return resolved
        }.sorted { ($0.product, $0.env) < ($1.product, $1.env) }

        insights.ages = zip(FleetInsights.ageBuckets, ageCounts).map {
            AgeBucket(label: $0.0.label, count: $0.1)
        }
        if unknownAge > 0 {
            // Reported rather than folded into "under a day": guessing young is
            // the flattering answer and it is the one that hides a parse bug.
            insights.ages.append(AgeBucket(label: "launch time unreadable",
                                           count: unknownAge))
        }

        insights.families = familyCounts.map { family, count in
            let type = InstanceType(family + ".large")
            return FamilyUse(family: family, count: count,
                             isBurstable: type.isBurstable,
                             isPreviousGeneration: type.isPreviousGeneration)
        }.sorted { ($1.count, $0.family) < ($0.count, $1.family) }

        insights.exposure = exposureCounts.map { env, counts in
            ExposureByEnv(env: env, withPublicAddress: counts.withPublic,
                          total: counts.total)
        }.sorted { $0.env < $1.env }

        return insights
    }

    static func ageIndex(of instance: Instance, now: Date) -> Int? {
        guard let launched = ISO8601DateFormatter().date(from: instance.launchTime)
        else { return nil }
        let days = now.timeIntervalSince(launched) / 86_400
        for (index, bucket) in ageBuckets.enumerated() {
            guard let upper = bucket.upperDays else { return index }
            if days < upper { return index }
        }
        return ageBuckets.count - 1
    }
}

/// How close to production an environment name reads.
///
/// Used to give the cluster depth that means something: production sits nearest
/// the hub, the further out a ring is the further it is from anything that
/// pages someone. The names are a heuristic over other people's conventions,
/// so anything unrecognised sits at the outside rather than being guessed into
/// the middle.
public enum EnvironmentTier: Int, Sendable, CaseIterable {
    case production = 0
    case staging = 1
    case testing = 2
    case development = 3
    case unknown = 4

    public static func of(_ env: String) -> EnvironmentTier {
        let name = env.lowercased()
        if name.contains("prod") || name.contains("prd") || name == "live" {
            return .production
        }
        if name.contains("stag") || name.contains("stg") || name.contains("uat")
            || name.contains("preprod") || name.contains("pre-prod") {
            return .staging
        }
        if name.contains("qa") || name.contains("test") || name.contains("demo") {
            return .testing
        }
        if name.contains("dev") || name.contains("sandbox") || name.contains("sb")
            || name.contains("local") {
            return .development
        }
        return .unknown
    }

    public var label: String {
        switch self {
        case .production:  return "production"
        case .staging:     return "staging"
        case .testing:     return "test"
        case .development: return "development"
        case .unknown:     return "other"
        }
    }
}
