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
