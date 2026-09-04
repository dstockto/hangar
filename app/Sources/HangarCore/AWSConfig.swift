import Foundation

/// Reads ~/.aws/config and ~/.aws/credentials. Both are INI-ish with the same
/// quirk: the default profile is [default] in one file and [default] in the
/// other, while named profiles are [profile x] in config but plain [x] in
/// credentials. Every consumer here goes through `profile(named:)`.
public struct AWSConfigFiles: Sendable {
    public var config: [String: [String: String]]
    public var credentials: [String: [String: String]]

    public init(config: [String: [String: String]],
                credentials: [String: [String: String]]) {
        self.config = config
        self.credentials = credentials
    }

    public static let defaultConfigPath =
        NSString(string: "~/.aws/config").expandingTildeInPath
    public static let defaultCredentialsPath =
        NSString(string: "~/.aws/credentials").expandingTildeInPath

    public static func load(
        configPath: String = defaultConfigPath,
        credentialsPath: String = defaultCredentialsPath
    ) -> AWSConfigFiles {
        AWSConfigFiles(config: parse(configPath), credentials: parse(credentialsPath))
    }

    static func parse(_ path: String) -> [String: [String: String]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            // Strip trailing comments, but only when the '#' starts a word so
            // that values legitimately containing '#' survive (SSO start URLs do).
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
            if let semi = line.range(of: " ;") { line = String(line[..<semi.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                sections[current] = sections[current] ?? [:]
                continue
            }
            guard let eq = line.firstIndex(of: "="), !current.isEmpty else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            sections[current]?[key] = value
        }
        return sections
    }

    /// Every profile name Hangar can offer, from either file.
    public var profileNames: [String] {
        var names = Set<String>()
        for key in config.keys {
            if key == "default" { names.insert("default") }
            else if key.hasPrefix("profile ") { names.insert(String(key.dropFirst(8))) }
        }
        for key in credentials.keys where !key.hasPrefix("sso-session ") {
            names.insert(key)
        }
        return names.sorted()
    }

    /// Every profile with what the picker needs to describe it: how it
    /// authenticates and where it points. A profile Hangar cannot use is listed
    /// too, labelled, because hiding it makes a mis-set AWS_PROFILE invisible.
    public var profileSummaries: [ProfileSummary] {
        profileNames.map { name in
            guard let profile = try? profile(named: name) else {
                return ProfileSummary(name: name, method: .unavailable, region: "")
            }
            return ProfileSummary(name: name, method: profile.method,
                                  region: profile.region)
        }
    }

    /// The profile a resolve with this request would actually read, which is what
    /// "Automatic" means on screen. Nil when exported keys win and no profile is
    /// consulted at all, so the UI never names a profile that had no say.
    public static func activeProfileName(
        requested: String?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let requested, !requested.isEmpty { return requested }
        if !(env["AWS_ACCESS_KEY_ID"] ?? "").isEmpty,
           !(env["AWS_SECRET_ACCESS_KEY"] ?? "").isEmpty { return nil }
        return env["AWS_PROFILE"] ?? "default"
    }

    func configSection(_ name: String) -> [String: String] {
        config[name == "default" ? "default" : "profile \(name)"] ?? [:]
    }

    /// Merged view of a profile. Values in ~/.aws/credentials win, matching the
    /// precedence the AWS CLI uses for the shared credentials file.
    public func profile(named requested: String? = nil) throws -> AWSProfile {
        let env = ProcessInfo.processInfo.environment
        let name = requested ?? env["AWS_PROFILE"] ?? "default"
        let fromConfig = configSection(name)
        let fromCredentials = credentials[name] ?? [:]
        var merged = fromConfig
        for (k, v) in fromCredentials { merged[k] = v }

        if merged.isEmpty {
            let available = profileNames.joined(separator: ", ")
            throw HangarError.noProfile(
                available.isEmpty
                    ? "no profiles found in ~/.aws/config or ~/.aws/credentials"
                    : "no profile '\(name)'. Available: \(available)")
        }

        // Region precedence: the profile's own setting, then the environment, then
        // the default profile's region. That last hop is a deliberate kindness to
        // old-style credentials-only profiles, which often carry no region at all
        // and would otherwise query us-east-1 and quietly come back empty.
        let region = merged["region"]
            ?? env["AWS_REGION"]
            ?? env["AWS_DEFAULT_REGION"]
            ?? config["default"]?["region"]
            ?? "us-east-1"

        var profile = AWSProfile(
            name: name,
            region: region,
            ssoSessionName: merged["sso_session"],
            ssoAccountId: merged["sso_account_id"],
            ssoRoleName: merged["sso_role_name"],
            ssoStartURL: merged["sso_start_url"],
            ssoRegion: merged["sso_region"],
            accessKeyId: merged["aws_access_key_id"],
            secretAccessKey: merged["aws_secret_access_key"],
            sessionToken: merged["aws_session_token"],
            roleArn: merged["role_arn"],
            sourceProfile: merged["source_profile"],
            externalId: merged["external_id"],
            roleSessionName: merged["role_session_name"],
            credentialProcess: merged["credential_process"]
        )

        // A profile pointing at an [sso-session] inherits its start URL and region.
        if let session = profile.ssoSessionName,
           let block = config["sso-session \(session)"] {
            profile.ssoStartURL = profile.ssoStartURL ?? block["sso_start_url"]
            profile.ssoRegion = profile.ssoRegion ?? block["sso_region"]
        }
        return profile
    }
}

public struct AWSProfile: Sendable {
    public var name: String
    public var region: String

    public var ssoSessionName: String?
    public var ssoAccountId: String?
    public var ssoRoleName: String?
    public var ssoStartURL: String?
    public var ssoRegion: String?

    public var accessKeyId: String?
    public var secretAccessKey: String?
    public var sessionToken: String?

    public var roleArn: String?
    public var sourceProfile: String?
    public var externalId: String?
    public var roleSessionName: String?
    public var credentialProcess: String?

    /// How this profile authenticates, decided in the order `CredentialResolver`
    /// tries them so the picker cannot disagree with the result.
    public enum CredentialMethod: Sendable, Equatable {
        case staticKeys, sso, assumedRole, credentialProcess, unavailable

        /// Short enough for a menu row.
        public var label: String {
            switch self {
            case .staticKeys:        return "static keys"
            case .sso:               return "SSO"
            case .assumedRole:       return "assumed role"
            case .credentialProcess: return "credential_process"
            case .unavailable:       return "no credentials"
            }
        }

        public var isUsable: Bool { self != .unavailable }
    }

    public var method: CredentialMethod {
        if hasStaticKeys { return .staticKeys }
        if isSSO { return .sso }
        if assumesRole { return .assumedRole }
        if !(credentialProcess ?? "").isEmpty { return .credentialProcess }
        return .unavailable
    }

    public var hasStaticKeys: Bool {
        !(accessKeyId ?? "").isEmpty && !(secretAccessKey ?? "").isEmpty
    }
    public var isSSO: Bool {
        !(ssoAccountId ?? "").isEmpty && !(ssoRoleName ?? "").isEmpty
            && !(ssoStartURL ?? "").isEmpty
    }
    public var assumesRole: Bool { !(roleArn ?? "").isEmpty }

    /// Convenience for callers that only need one profile.
    public static func load(profile: String? = nil) throws -> AWSProfile {
        try AWSConfigFiles.load().profile(named: profile)
    }
}

/// One profile as the pickers show it. Kept UI-free so the setup window and the
/// menubar describe a profile the same way.
public struct ProfileSummary: Sendable, Equatable, Identifiable {
    public var name: String
    public var method: AWSProfile.CredentialMethod
    public var region: String

    public var id: String { name }
    public var isUsable: Bool { method.isUsable }

    public init(name: String, method: AWSProfile.CredentialMethod, region: String) {
        self.name = name
        self.method = method
        self.region = region
    }

    /// "static keys  ·  us-west-2", per the brand kit's status format.
    public var detail: String {
        guard isUsable, !region.isEmpty else { return method.label }
        return "\(method.label)  \u{00B7}  \(region)"
    }
}
