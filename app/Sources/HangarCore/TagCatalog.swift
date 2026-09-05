import Foundation

/// The tag keys a fleet actually uses.
///
/// The defaults in `TagMapping` cover the conventions in common use, but guessing
/// is guessing. Once Hangar has fetched a fleet it knows exactly which keys exist
/// and what they contain, so the setup screen can show them and let the user
/// point each idea at the right one. That turns "your fleet is untagged" from a
/// dead end into a two-click fix.
///
/// Built from the tags as they came back from AWS, before normalization: after
/// normalization the canonical keys are present whether the fleet uses them or
/// not, and suggesting `product` to someone who has never used it is worse than
/// suggesting nothing.
public struct TagCatalog: Codable, Sendable, Equatable {
    public struct Key: Codable, Sendable, Equatable, Identifiable, Hashable {
        /// The tag key, exactly as AWS returned it.
        public var name: String
        /// How many instances carry it. A key on 2 of 249 hosts is not the one
        /// that groups the fleet.
        public var instances: Int
        /// How many distinct values it takes. A key with one value groups nothing;
        /// a key with as many values as instances is an identifier, not a group.
        public var distinctValues: Int
        /// A few real values, so the user can recognise the key by its contents.
        public var samples: [String]

        public var id: String { name }

        public init(name: String, instances: Int, distinctValues: Int, samples: [String]) {
            self.name = name
            self.instances = instances
            self.distinctValues = distinctValues
            self.samples = samples
        }

        /// How useful this key looks for grouping: carried by most of the fleet,
        /// and taking more than one value but far fewer than one per host.
        public func groupingScore(fleetSize: Int) -> Double {
            guard fleetSize > 0, instances > 0, distinctValues > 1 else { return 0 }
            let coverage = Double(instances) / Double(fleetSize)
            let spread = Double(distinctValues) / Double(instances)
            // Peaks around a handful of values across the whole fleet.
            return coverage * (1 - min(spread, 1))
        }
    }

    public var keys: [Key]
    public var fleetSize: Int

    public init(keys: [Key], fleetSize: Int) {
        self.keys = keys
        self.fleetSize = fleetSize
    }

    public static let empty = TagCatalog(keys: [], fleetSize: 0)

    /// AWS-managed tags. Real, and worth nothing to a person choosing a grouping,
    /// so they stay out of the picker. `aws:autoscaling:groupName` is read
    /// directly elsewhere and does not need mapping.
    static func isReserved(_ key: String) -> Bool { key.hasPrefix("aws:") }

    public static func discover(from instances: [Instance]) -> TagCatalog {
        var counts: [String: Int] = [:]
        var values: [String: Set<String>] = [:]
        for instance in instances {
            for (key, value) in instance.tags where !isReserved(key) && !value.isEmpty {
                counts[key, default: 0] += 1
                values[key, default: []].insert(value)
            }
        }
        let keys = counts.map { name, count -> Key in
            let distinct = values[name] ?? []
            return Key(name: name, instances: count, distinctValues: distinct.count,
                       samples: distinct.sorted().prefix(3).map { $0 })
        }
        // Most-carried first, then most useful for grouping, then by name so the
        // order is stable between runs.
        let size = instances.count
        let sorted = keys.sorted {
            if $0.instances != $1.instances { return $0.instances > $1.instances }
            let left = $0.groupingScore(fleetSize: size)
            let right = $1.groupingScore(fleetSize: size)
            if left != right { return left > right }
            return $0.name < $1.name
        }
        return TagCatalog(keys: sorted, fleetSize: size)
    }

    public var isEmpty: Bool { keys.isEmpty }

    /// The keys a filter will not read the tag for, worked out from the answers
    /// rather than from the list of names `tagValue(for:)` intercepts.
    ///
    /// Membership in that list is the wrong question. Four of the nine are first
    /// in their own candidate list, so on a fleet that spells them canonically
    /// `env` resolves from `env` and `-f env=prod` reads the tag it looks like it
    /// reads. Marking those would name the keys a reader uses most as the ones
    /// they cannot select on. A key is shadowed only when some host answers
    /// differently from the tag it carries, which also catches the cases a name
    /// list cannot: a config that puts `Name` first in the product candidates
    /// shadows `product`, and one that reorders the hostname candidates shadows
    /// `hostname`, which is not in the list at all.
    /// `raw` and `resolved` are the same hosts in the same order, which is what
    /// `TagMapping.normalize` produces because it is a map. Stated because this
    /// is public and zipping mismatched fleets would compare one host's answer
    /// against another host's tag.
    public static func shadowedKeys(among keys: [String], raw: [Instance],
                                    resolved: [Instance]) -> Set<String> {
        var shadowed: Set<String> = []
        for (rawHost, resolvedHost) in zip(raw, resolved) {
            for key in keys where !shadowed.contains(key) {
                if resolvedHost.tagValue(for: key) != (rawHost.tags[key] ?? "") {
                    shadowed.insert(key)
                }
            }
        }
        return shadowed
    }

    /// One value a tag takes, and how many hosts carry it.
    public struct ValueCount: Equatable, Sendable {
        public var value: String
        public var hosts: Int

        public init(value: String, hosts: Int) {
            self.value = value
            self.hosts = hosts
        }
    }

    /// Every value one key takes across a fleet, most-used first.
    ///
    /// Reads through `tagValue(for:)` rather than the raw tags, so what this
    /// lists is exactly what `-f <key>=` will match. A list of values you cannot
    /// then select on would be worse than no list.
    public static func values(of key: String, in instances: [Instance]) -> [ValueCount] {
        var counts: [String: Int] = [:]
        for instance in instances {
            let value = instance.tagValue(for: key)
            guard !value.isEmpty else { continue }
            counts[value, default: 0] += 1
        }
        return counts
            .map { ValueCount(value: $0.key, hosts: $0.value) }
            .sorted { $0.hosts != $1.hosts ? $0.hosts > $1.hosts : $0.value < $1.value }
    }

    public func key(named name: String) -> Key? { keys.first { $0.name == name } }

    /// The key a mapping would currently resolve for one idea, if the fleet has
    /// it. Used to preselect the picker so it opens showing the truth.
    public func resolved(for candidates: [String]) -> String? {
        for candidate in candidates where key(named: candidate) != nil { return candidate }
        let lowered = Dictionary(keys.map { ($0.name.lowercased(), $0.name) },
                                uniquingKeysWith: { first, _ in first })
        for candidate in candidates {
            if let match = lowered[candidate.lowercased()] { return match }
        }
        return nil
    }

    /// The best guess for an idea the mapping does not currently resolve: the
    /// highest-scoring key whose name looks related, else nothing. Deliberately
    /// conservative, because a wrong guess presented as a suggestion is worse
    /// than an empty picker.
    public func suggestion(for concept: Concept) -> String? {
        keys
            .filter { concept.hints.contains(where: $0.name.lowercased().contains) }
            .max { $0.groupingScore(fleetSize: fleetSize) < $1.groupingScore(fleetSize: fleetSize) }?
            .name
    }

    /// The four ideas Hangar groups and names hosts by, plus the hostname.
    public enum Concept: String, CaseIterable, Sendable {
        case product, env, envName, role, hostname

        /// Named by what it does, not by the tag we happen to call it
        /// internally. "Product" and "Environment" are one industry's
        /// vocabulary; a fleet organised by team, service or business unit has
        /// the same three levels under different words, and being told to fill
        /// in "Product" when you have no such concept is its own small barrier.
        public var title: String {
            switch self {
            case .product:  return "Top-level grouping"
            case .env:      return "Second grouping"
            case .envName:  return "Third grouping"
            case .role:     return "Host label"
            case .hostname: return "Address to connect to"
            }
        }

        public var explanation: String {
            switch self {
            case .product:
                return "First level of the menu. Often product, service, team or app."
            case .env:
                return "Second level, and what marks production. Often env, stage or tier."
            case .envName:
                return "Optional. Tells parallel copies of one environment apart."
            case .role:
                return "Names the host in its alias. Often Name, role or component."
            case .hostname:
                return "What ssh connects to. The private IP if no tag is chosen."
            }
        }

        /// Substrings that suggest a key means this idea.
        var hints: [String] {
            switch self {
            case .product:  return ["product", "service", "app", "project", "system", "team"]
            case .env:      return ["env", "stage", "tier"]
            case .envName:  return ["env_name", "envname", "cluster", "instance_name"]
            case .role:     return ["name", "role", "component", "function", "purpose"]
            case .hostname: return ["host", "fqdn", "dns", "address"]
            }
        }

        public func candidates(in mapping: TagMapping) -> [String] {
            switch self {
            case .product:  return mapping.product
            case .env:      return mapping.env
            case .envName:  return mapping.envName
            case .role:     return mapping.role
            case .hostname: return mapping.hostname
            }
        }
    }
}

public extension TagMapping {
    /// Points one idea at one tag key, keeping the defaults behind it so a fleet
    /// that is not entirely consistent still resolves. Passing nil means the idea
    /// resolves to nothing, which is a legitimate choice: not every fleet has a
    /// second grouping.
    mutating func use(_ key: String?, for concept: TagCatalog.Concept) {
        let fallbacks = concept.candidates(in: .standard)
        let list: [String]
        if let key, !key.isEmpty {
            list = [key] + fallbacks.filter { $0.caseInsensitiveCompare(key) != .orderedSame }
        } else {
            list = []
        }
        switch concept {
        case .product:  product = list
        case .env:      env = list
        case .envName:  envName = list
        case .role:     role = list
        case .hostname: hostname = list
        }
    }

    /// The key this mapping resolves for an idea against a given fleet.
    func resolvedKey(for concept: TagCatalog.Concept, in catalog: TagCatalog) -> String? {
        catalog.resolved(for: concept.candidates(in: self))
    }
}
