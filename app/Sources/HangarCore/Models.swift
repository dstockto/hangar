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

    public init(id: String, state: String, type: String, privateIP: String?,
                publicIP: String?, availabilityZone: String?, launchTime: String,
                tags: [String: String]) {
        self.id = id
        self.state = state
        self.type = type
        self.privateIP = privateIP
        self.publicIP = publicIP
        self.availabilityZone = availabilityZone
        self.launchTime = launchTime
        self.tags = tags
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
        let parts = [product, env, envName, role].map(Instance.slug).filter { !$0.isEmpty }
        return parts.isEmpty ? Instance.slug(id) : parts.joined(separator: "-")
    }

    /// The alias with the grouping it already sits under removed, for display in
    /// a product → env submenu where repeating both would be noise.
    public func leafLabel(alias: String) -> String {
        let prefix = [product, env].map(Instance.slug).filter { !$0.isEmpty }
            .joined(separator: "-") + "-"
        guard prefix.count > 1, alias.hasPrefix(prefix) else { return alias }
        return String(alias.dropFirst(prefix.count))
    }

    static func slug(_ text: String) -> String {
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
    case noSSOToken(String)
    case ssoTokenExpired(String)
    case http(Int, String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .noProfile(let m):        return "AWS profile problem: \(m)"
        case .noSSOToken(let m):       return "No usable SSO token: \(m)"
        case .ssoTokenExpired(let m):  return "SSO session expired: \(m)"
        case .http(let code, let m):   return "HTTP \(code): \(m)"
        case .malformedResponse(let m):return "Unexpected response: \(m)"
        }
    }
}
