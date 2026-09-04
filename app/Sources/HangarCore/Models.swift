import Foundation

/// One EC2 instance, reduced to what Hangar needs to show it and ssh to it.
public struct Instance: Sendable, Hashable, Codable {
    public var id: String
    public var state: String
    public var type: String
    public var privateIP: String?
    public var publicIP: String?
    public var availabilityZone: String?
    public var launchTime: String
    public var tags: [String: String]
    /// The rest of what DescribeInstances says about an instance. All optional,
    /// because a cache written before these existed has to keep decoding, and
    /// all free: they came back in the same response as everything above.
    public var imageID: String?
    public var vpcID: String?
    public var subnetID: String?
    public var keyName: String?
    public var iamProfile: String?
    public var architecture: String?
    public var platform: String?
    /// "spot" or "scheduled" when the instance is not on demand.
    public var lifecycle: String?
    public var cores: Int?
    public var threadsPerCore: Int?
    public var privateDNS: String?
    public var securityGroups: [String]?
    public var monitoring: String?
    public var rootDeviceType: String?
    public var stateReason: String?
    /// Which source produced this host. Nil means EC2: a cache written before
    /// there was more than one source has to keep decoding.
    public var source: HostSource?
    /// The name this host is already known by, set by every source that does not
    /// invent its own. Kept verbatim rather than slugified, because for an
    /// imported host it is the name ssh already resolves and changing it would
    /// produce an alias that does not work.
    public var preferredAlias: String?

    public init(id: String, state: String, type: String, privateIP: String?,
                publicIP: String?, availabilityZone: String?, launchTime: String,
                tags: [String: String], imageID: String? = nil, vpcID: String? = nil,
                subnetID: String? = nil, keyName: String? = nil,
                iamProfile: String? = nil, architecture: String? = nil,
                platform: String? = nil, lifecycle: String? = nil,
                cores: Int? = nil, threadsPerCore: Int? = nil,
                privateDNS: String? = nil, securityGroups: [String]? = nil,
                monitoring: String? = nil, rootDeviceType: String? = nil,
                stateReason: String? = nil, source: HostSource? = nil,
                preferredAlias: String? = nil) {
        self.id = id
        self.state = state
        self.type = type
        self.privateIP = privateIP
        self.publicIP = publicIP
        self.availabilityZone = availabilityZone
        self.launchTime = launchTime
        self.tags = tags
        self.imageID = imageID
        self.vpcID = vpcID
        self.subnetID = subnetID
        self.keyName = keyName
        self.iamProfile = iamProfile
        self.architecture = architecture
        self.platform = platform
        self.lifecycle = lifecycle
        self.cores = cores
        self.threadsPerCore = threadsPerCore
        self.privateDNS = privateDNS
        self.securityGroups = securityGroups
        self.monitoring = monitoring
        self.rootDeviceType = rootDeviceType
        self.stateReason = stateReason
        self.source = source
        self.preferredAlias = preferredAlias
    }

    /// The source, with the pre-provenance default filled in.
    public var origin: HostSource { source ?? .ec2 }

    /// Whether Hangar writes this host into its own ssh_config include, or leaves
    /// it to the config the user already has.
    public var isWrittenToSSHConfig: Bool { origin.writesSSHConfig }

    /// vCPUs, when the response said how the cores are laid out.
    public var vcpus: Int? {
        guard let cores, let threadsPerCore else { return nil }
        return cores * threadsPerCore
    }

    public var product: String { tags["product"] ?? "" }
    public var env: String { tags["env"] ?? "" }
    public var envName: String { tags["env_name"] ?? "" }
    public var role: String { tags["Name"] ?? "" }
    public var asg: String { tags["aws:autoscaling:groupName"] ?? "" }
    public var isASG: Bool { !asg.isEmpty }

    /// The hostname tag when the instance has been through the assign step,
    /// otherwise the private IP. ASG instances carry an instance-id prefix here.
    public var host: String? {
        if let h = tags["hostname"], !h.isEmpty { return h }
        return privateIP
    }

    /// Slugified `product-env-env_name-role`, the stem of the ssh alias.
    ///
    /// Product has to be in here. Without it every product's production web box
    /// shares one `prod-web` group, so they get numbered against each other and
    /// `ssh prod-web-1` can land on a different product's server than you meant.
    /// Ordered widest to narrowest so aliases sort into the same shape as the menu.
    public var aliasStem: String {
        // A host that already has a name keeps it. Slugifying an imported alias
        // would produce something ssh cannot resolve, which is worse than an
        // alias that does not match the house style.
        if let preferredAlias, !preferredAlias.isEmpty { return preferredAlias }
        let parts = [product, env, envName, role].map(Instance.slug).filter { !$0.isEmpty }
        return parts.isEmpty ? Instance.slug(id) : parts.joined(separator: "-")
    }

    /// The alias with the grouping it already sits under removed, for display in
    /// a product → env submenu where repeating both would be noise.
    ///
    /// The levels come from the menu that is being built, not from a guess. When
    /// they were assumed to be product and env, a fleet grouped by product alone
    /// lost the env from every label and listed `web-1` three times, once per
    /// environment, with nothing to tell them apart.
    public func leafLabel(alias: String, groupedBy keys: [String]) -> String {
        let prefix = keys.map { Instance.slug(tagValue(for: $0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "-") + "-"
        guard prefix.count > 1, alias.hasPrefix(prefix) else { return alias }
        return String(alias.dropFirst(prefix.count))
    }

    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastWasDash = false
            } else if !lastWasDash {
                out.append("-"); lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public struct AWSCredentials: Sendable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyId: String, secretAccessKey: String,
                sessionToken: String?, expiration: Date?) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    public var isExpired: Bool {
        guard let expiration else { return false }
        return expiration.timeIntervalSinceNow < 60
    }
}

public enum HangarError: LocalizedError {
    case noProfile(String)
    /// The profile exists but carries nothing Hangar can authenticate with, which
    /// is a different fault from a missing profile: another profile may work.
    case noCredentials(profile: String)
    case noSSOToken(String)
    case ssoTokenExpired(String)
    case http(Int, String)
    case malformedResponse(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .noProfile(let m):        return "AWS profile problem: \(m)"
        case .noCredentials(let p):    return "AWS profile problem: profile '\(p)' has "
                                            + "no credentials Hangar can use"
        case .noSSOToken(let m):       return "No usable SSO token: \(m)"
        case .ssoTokenExpired(let m):  return "SSO session expired: \(m)"
        case .http(let code, let m):   return "HTTP \(code): \(m)"
        case .malformedResponse(let m):return "Unexpected response: \(m)"
        case .timedOut(let m):         return "Timed out: \(m)"
        }
    }
}
