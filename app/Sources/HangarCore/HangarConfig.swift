import Foundation

/// Everything Hangar reads about itself lives in ~/.hangar. One directory, no
/// preferences database, no defaults domain, so it can be inspected and edited
/// by hand and version controlled if the user wants to.
public struct HangarConfig: Codable, Sendable {
    public struct SSHSettings: Codable, Sendable {
        public var user: String?
        public var identityFile: String?
        public var knownHostsFile: String?
        public var strictHostKeyChecking: String?
        public var extraOptions: [String: String]?

        public init(user: String? = nil, identityFile: String? = nil,
                    knownHostsFile: String? = nil, strictHostKeyChecking: String? = nil,
                    extraOptions: [String: String]? = nil) {
            self.user = user
            self.identityFile = identityFile
            self.knownHostsFile = knownHostsFile
            self.strictHostKeyChecking = strictHostKeyChecking
            self.extraOptions = extraOptions
        }

        enum CodingKeys: String, CodingKey {
            case user
            case identityFile = "identity_file"
            case knownHostsFile = "known_hosts_file"
            case strictHostKeyChecking = "strict_host_key_checking"
            case extraOptions = "extra_options"
        }
    }

    /// A conditional block of ssh settings. `match` keys are instance tags and
    /// accept `*` wildcards; blocks are applied top to bottom and merged, so
    /// general rules go first and specific ones after.
    public struct Override: Codable, Sendable {
        public var match: [String: String]
        public var user: String?
        public var identityFile: String?
        public var knownHostsFile: String?
        public var strictHostKeyChecking: String?
        public var extraOptions: [String: String]?

        public init(match: [String: String], user: String? = nil,
                    identityFile: String? = nil, knownHostsFile: String? = nil,
                    strictHostKeyChecking: String? = nil,
                    extraOptions: [String: String]? = nil) {
            self.match = match
            self.user = user
            self.identityFile = identityFile
            self.knownHostsFile = knownHostsFile
            self.strictHostKeyChecking = strictHostKeyChecking
            self.extraOptions = extraOptions
        }

        enum CodingKeys: String, CodingKey {
            case match, user
            case identityFile = "identity_file"
            case knownHostsFile = "known_hosts_file"
            case strictHostKeyChecking = "strict_host_key_checking"
            case extraOptions = "extra_options"
        }
    }

    public struct Hotkey: Codable, Sendable {
        public var keys: String
        public var title: String?
        public var filter: [String: String]?

        public init(keys: String, title: String? = nil, filter: [String: String]? = nil) {
            self.keys = keys
            self.title = title
            self.filter = filter
        }
    }

    public var profile: String?
    public var region: String?
    public var terminal: String?
    public var ssh: SSHSettings?
    public var overrides: [Override]?
    public var hotkeys: [Hotkey]?
    public var refreshMinutes: Int?
    public var syncSSHConfigOnRefresh: Bool?
    /// How recent the cache must be for Hangar to consider the fleet healthy.
    public var healthyWithinHours: Int?
    /// Which releases Check for Updates offers: "stable" sees only full releases,
    /// "beta" also sees prerelease builds.
    public var updateChannel: String?
    /// Whether Hangar checks for a new release on its own. On by default, at most
    /// once every `update_check_hours`; set false and it only checks when asked.
    public var checkUpdatesOnLaunch: Bool?
    /// Mirrors the macOS login item. The system is the source of truth; this records
    /// the user's intent so the setup screen can show it without querying.
    public var launchAtLogin: Bool?
    /// Which EC2 tags mean product, env, role and hostname. Defaults cover the
    /// common conventions; a fleet that spells them differently adds its keys here.
    public var tags: TagMapping?
    /// How often the background update check runs. Zero or nil turns it off.
    public var updateCheckHours: Int?

    public init(profile: String? = nil, region: String? = nil, terminal: String? = nil,
                ssh: SSHSettings? = nil, overrides: [Override]? = nil,
                hotkeys: [Hotkey]? = nil, refreshMinutes: Int? = nil,
                syncSSHConfigOnRefresh: Bool? = nil, healthyWithinHours: Int? = nil,
                updateChannel: String? = nil, checkUpdatesOnLaunch: Bool? = nil,
                launchAtLogin: Bool? = nil, tags: TagMapping? = nil,
                updateCheckHours: Int? = nil) {
        self.profile = profile
        self.region = region
        self.terminal = terminal
        self.ssh = ssh
        self.overrides = overrides
        self.hotkeys = hotkeys
        self.refreshMinutes = refreshMinutes
        self.syncSSHConfigOnRefresh = syncSSHConfigOnRefresh
        self.healthyWithinHours = healthyWithinHours
        self.updateChannel = updateChannel
        self.checkUpdatesOnLaunch = checkUpdatesOnLaunch
        self.launchAtLogin = launchAtLogin
        self.tags = tags
        self.updateCheckHours = updateCheckHours
    }

    enum CodingKeys: String, CodingKey {
        case profile, region, terminal, ssh, overrides, hotkeys
        case refreshMinutes = "refresh_minutes"
        case syncSSHConfigOnRefresh = "sync_ssh_config_on_refresh"
        case healthyWithinHours = "healthy_within_hours"
        case updateChannel = "update_channel"
        case checkUpdatesOnLaunch = "check_updates_on_launch"
        case launchAtLogin = "launch_at_login"
        case tags
        case updateCheckHours = "update_check_hours"
    }

    public static var home: String {
        NSString(string: "~/.hangar").expandingTildeInPath
    }
    public static var path: String {
        (home as NSString).appendingPathComponent("config.json")
    }
    public static var cachePath: String {
        (home as NSString).appendingPathComponent("cache/instances.json")
    }
    /// Written once the user has been through the setup check, so it only appears
    /// unprompted on a genuinely fresh install.
    public static var onboardedMarkerPath: String {
        (home as NSString).appendingPathComponent(".setup-complete")
    }
    public static var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: onboardedMarkerPath)
    }
    public static func markOnboarded() {
        try? FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: onboardedMarkerPath, contents: Data())
    }

    /// The configured mapping, or the defaults when the config predates it.
    public var tagMapping: TagMapping { tags ?? .standard }

    public static var sshIncludePath: String {
        NSString(string: "~/.ssh/config.d/hangar").expandingTildeInPath
    }

    public static func standard() -> HangarConfig {
        HangarConfig(
            profile: nil, region: nil, terminal: "iterm",
            ssh: SSHSettings(
                user: NSUserName(),
                identityFile: nil,
                knownHostsFile: "~/.ssh/known_hosts.ec2",
                strictHostKeyChecking: "accept-new",
                extraOptions: [:]),
            overrides: [],
            hotkeys: [Hotkey(keys: "cmd+shift+h", title: "All hosts", filter: [:])],
            refreshMinutes: 30,
            syncSSHConfigOnRefresh: true,
            healthyWithinHours: 24,
            updateChannel: "stable",
            checkUpdatesOnLaunch: true,
            launchAtLogin: false,
            tags: .standard,
            updateCheckHours: 24)
    }

    /// Loads the config, writing a documented starter file on first run. A config
    /// that fails to parse is reported rather than silently replaced, so a typo
    /// never costs the user their settings.
    public static func load() throws -> HangarConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try write(standard())
            return standard()
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(HangarConfig.self, from: data)
        } catch {
            throw HangarError.malformedResponse(
                "\(path) is not valid Hangar config: \(error.localizedDescription)")
        }
    }

    public static func write(_ config: HangarConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Effective ssh settings for one instance, defaults merged with any matching
    /// override blocks in order.
    public func sshSettings(for instance: Instance) -> SSHSettings {
        var result = ssh ?? SSHSettings(user: NSUserName(), identityFile: nil,
                                        knownHostsFile: nil,
                                        strictHostKeyChecking: nil, extraOptions: nil)
        for override in overrides ?? [] where HangarConfig.matches(override.match, instance) {
            if let v = override.user { result.user = v }
            if let v = override.identityFile { result.identityFile = v }
            if let v = override.knownHostsFile { result.knownHostsFile = v }
            if let v = override.strictHostKeyChecking { result.strictHostKeyChecking = v }
            if let v = override.extraOptions {
                var merged = result.extraOptions ?? [:]
                for (k, value) in v { merged[k] = value }
                result.extraOptions = merged
            }
        }
        return result
    }

    /// Inserts or replaces an override for exactly this `match`, then reorders so
    /// general rules stay ahead of specific ones. Overrides merge top to bottom,
    /// so a host-scoped rule has to sit after a product-scoped one to win.
    /// Passing empty values removes the override instead of writing blanks.
    public mutating func setOverride(match: [String: String],
                                    user: String?, identityFile: String?) {
        var list = overrides ?? []
        let cleanUser = (user?.isEmpty ?? true) ? nil : user
        let cleanKey = (identityFile?.isEmpty ?? true) ? nil : identityFile
        list.removeAll { $0.match == match }
        if cleanUser != nil || cleanKey != nil {
            list.append(Override(match: match, user: cleanUser, identityFile: cleanKey))
        }
        overrides = list.sorted { HangarConfig.specificity($0) < HangarConfig.specificity($1) }
    }

    public func override(for match: [String: String]) -> Override? {
        (overrides ?? []).first { $0.match == match }
    }

    /// More match keys means more specific; an instance id pins one machine and
    /// is therefore the most specific thing an override can name.
    static func specificity(_ override: Override) -> Int {
        let pinsInstance = override.match.keys.contains { key in
            let lowered = key.lowercased()
            return lowered == "id" || lowered == "instance_id"
        }
        return override.match.count + (pinsInstance ? 100 : 0)
    }

    static func matches(_ match: [String: String], _ instance: Instance) -> Bool {
        guard !match.isEmpty else { return false }
        return match.allSatisfy { key, pattern in
            wildcard(pattern, instance.tagValue(for: key))
        }
    }

    /// Shell-style `*` matching, used for both override blocks and hotkey filters.
    public static func wildcard(_ pattern: String, _ value: String) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        guard pattern.contains("*") else { return pattern == value }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}

public extension Instance {
    /// Tag lookup that accepts the friendly names used in config files, so a user
    /// can write `name` rather than remembering the tag is capitalised `Name`.
    func tagValue(for key: String) -> String {
        switch key.lowercased() {
        case "name", "role":  return role
        case "env":           return env
        case "env_name":      return envName
        case "product":       return product
        case "asg":           return asg
        case "state":         return state
        case "id", "instance_id": return id
        default:              return tags[key] ?? ""
        }
    }
}
