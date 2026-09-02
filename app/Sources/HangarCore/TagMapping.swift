import Foundation

/// Which EC2 tags mean what.
///
/// Hangar groups and names hosts from four ideas: product, environment, a name
/// for parallel environments, and the machine's role. Almost every fleet has all
/// four somewhere in its tags, and almost none of them agree on the spelling.
/// `Service`, `App` and `product` are the same idea; so are `Environment`, `Env`
/// and `stage`.
///
/// So the mapping is a list of candidate keys per idea, tried in order, matched
/// case-insensitively. The defaults cover the conventions in common use, and a
/// fleet that uses something else adds its own key to `~/.hangar/config.json`
/// rather than retagging every instance.
public struct TagMapping: Codable, Sendable, Equatable {
    public var product: [String]
    public var env: [String]
    public var envName: [String]
    public var role: [String]
    public var hostname: [String]

    enum CodingKeys: String, CodingKey {
        case product, env, role, hostname
        case envName = "env_name"
    }

    public init(product: [String], env: [String], envName: [String],
                role: [String], hostname: [String]) {
        self.product = product
        self.env = env
        self.envName = envName
        self.role = role
        self.hostname = hostname
    }

    /// Canonical keys, the ones the rest of Hangar reads after normalization.
    public enum Canonical {
        public static let product = "product"
        public static let env = "env"
        public static let envName = "env_name"
        public static let role = "Name"
        public static let hostname = "hostname"
    }

    public static let standard = TagMapping(
        product: ["product", "Product", "service", "Service", "app", "App",
                  "Application", "project", "Project", "system", "System"],
        env: ["env", "Env", "environment", "Environment", "stage", "Stage",
              "tier", "Tier"],
        envName: ["env_name", "envName", "EnvName", "environment_name",
                  "instance_name", "cluster", "Cluster"],
        role: ["Name", "name", "role", "Role", "component", "Component",
               "function", "Function", "purpose", "Purpose"],
        hostname: ["hostname", "Hostname", "HostName", "host", "Host",
                   "fqdn", "FQDN", "dns", "DNS", "dns_name", "DNSName"])

    /// First candidate present in `tags`, matched exactly first and then
    /// case-insensitively, so `Environment` and `environment` both land.
    public func value(for candidates: [String], in tags: [String: String]) -> String? {
        for key in candidates {
            if let value = tags[key], !value.isEmpty { return value }
        }
        let lowered = Dictionary(
            tags.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        for key in candidates {
            if let value = lowered[key.lowercased()], !value.isEmpty { return value }
        }
        return nil
    }

    /// Rewrites one instance's tags so the canonical keys carry the resolved
    /// values. Everything downstream reads canonical keys and needs no idea that
    /// the fleet spells them differently. The original tags are kept, so a
    /// filter or an override can still name any tag the instance actually has.
    public func normalize(_ instance: Instance) -> Instance {
        var normalized = instance
        let resolved: [(String, [String])] = [
            (Canonical.product, product),
            (Canonical.env, env),
            (Canonical.envName, envName),
            (Canonical.role, role),
            (Canonical.hostname, hostname),
        ]
        for (canonical, candidates) in resolved {
            if let found = value(for: candidates, in: instance.tags) {
                normalized.tags[canonical] = found
            } else {
                // A canonical key that resolved to nothing must not linger from a
                // previous mapping, or a stale cache would outvote the new config.
                normalized.tags.removeValue(forKey: canonical)
            }
        }
        return normalized
    }

    public func normalize(_ instances: [Instance]) -> [Instance] {
        instances.map(normalize)
    }

    /// True when this fleet gave Hangar nothing to group or name a host by. The
    /// setup check turns this into advice rather than an empty menu.
    public static func isUngrouped(_ instance: Instance) -> Bool {
        instance.product.isEmpty && instance.env.isEmpty && instance.role.isEmpty
    }
}
