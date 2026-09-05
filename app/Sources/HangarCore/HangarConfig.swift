import Foundation

/// Everything Hangar reads about itself lives in ~/.hangar. One directory, no
/// preferences database, no defaults domain, so it can be inspected and edited
/// by hand and version controlled if the user wants to.
public struct HangarConfig: Codable, Sendable {
    public struct SSHSettings: Codable, Sendable {
        public var user: String?
        public var identityFile: String?
        /// The socket of an ssh agent holding the key, when the key does not live
        /// in a file. 1Password, Secretive and a forwarded agent all look the same
        /// from here.
        public var identityAgent: String?
        /// Whether ssh may offer keys other than the pinned one. Nil keeps the
        /// old behaviour, which is yes when a key is pinned and silent otherwise.
        /// Explicit false is the escape hatch: pin a key and still let the agent
        /// offer its own, which is what someone on a vault needs.
        public var identitiesOnly: Bool?
        public var knownHostsFile: String?
        public var strictHostKeyChecking: String?
        public var extraOptions: [String: String]?

        public init(user: String? = nil, identityFile: String? = nil,
                    identityAgent: String? = nil, identitiesOnly: Bool? = nil,
                    knownHostsFile: String? = nil, strictHostKeyChecking: String? = nil,
                    extraOptions: [String: String]? = nil) {
            self.user = user
            self.identityFile = identityFile
            self.identityAgent = identityAgent
            self.identitiesOnly = identitiesOnly
            self.knownHostsFile = knownHostsFile
            self.strictHostKeyChecking = strictHostKeyChecking
            self.extraOptions = extraOptions
        }

        /// Whether `IdentitiesOnly yes` belongs in the file. A pinned key with no
        /// opinion recorded keeps the behaviour that shipped.
        public var pinsIdentities: Bool {
            identitiesOnly ?? (identityFile?.isEmpty == false)
        }

        enum CodingKeys: String, CodingKey {
            case user
            case identityFile = "identity_file"
            case identityAgent = "identity_agent"
            case identitiesOnly = "identities_only"
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
        public var identityAgent: String?
        public var identitiesOnly: Bool?
        public var knownHostsFile: String?
        public var strictHostKeyChecking: String?
        public var extraOptions: [String: String]?

        public init(match: [String: String], user: String? = nil,
                    identityFile: String? = nil, identityAgent: String? = nil,
                    identitiesOnly: Bool? = nil, knownHostsFile: String? = nil,
                    strictHostKeyChecking: String? = nil,
                    extraOptions: [String: String]? = nil) {
            self.match = match
            self.user = user
            self.identityFile = identityFile
            self.identityAgent = identityAgent
            self.identitiesOnly = identitiesOnly
            self.knownHostsFile = knownHostsFile
            self.strictHostKeyChecking = strictHostKeyChecking
            self.extraOptions = extraOptions
        }

        enum CodingKeys: String, CodingKey {
            case match, user
            case identityFile = "identity_file"
            case identityAgent = "identity_agent"
            case identitiesOnly = "identities_only"
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
    /// Whether Hangar keeps the one-line `Include` in ~/.ssh/config in step with
    /// the aliases it writes. On by default: aliases no terminal can see are not
    /// a feature with an optional extra step. Set false to manage that line
    /// yourself, and Hangar will stop putting it back.
    public var manageSSHInclude: Bool?
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
    /// One menubar submenu level per tag key, in order. Any tag key works, not
    /// only the ones Hangar maps. Nil keeps the default product, env, env_name.
    public var groupBy: [String]?
    /// Where Hangar looks for hosts. Nil is every source at its own default,
    /// which is what someone who never opens this file should get.
    public var sources: SourceSettings?

    public init(profile: String? = nil, region: String? = nil, terminal: String? = nil,
                ssh: SSHSettings? = nil, overrides: [Override]? = nil,
                hotkeys: [Hotkey]? = nil, refreshMinutes: Int? = nil,
                syncSSHConfigOnRefresh: Bool? = nil, manageSSHInclude: Bool? = nil,
                healthyWithinHours: Int? = nil,
                updateChannel: String? = nil, checkUpdatesOnLaunch: Bool? = nil,
                launchAtLogin: Bool? = nil, tags: TagMapping? = nil,
                updateCheckHours: Int? = nil, groupBy: [String]? = nil,
                sources: SourceSettings? = nil) {
        self.profile = profile
        self.region = region
        self.terminal = terminal
        self.ssh = ssh
        self.overrides = overrides
        self.hotkeys = hotkeys
        self.refreshMinutes = refreshMinutes
        self.syncSSHConfigOnRefresh = syncSSHConfigOnRefresh
        self.manageSSHInclude = manageSSHInclude
        self.healthyWithinHours = healthyWithinHours
        self.updateChannel = updateChannel
        self.checkUpdatesOnLaunch = checkUpdatesOnLaunch
        self.launchAtLogin = launchAtLogin
        self.tags = tags
        self.updateCheckHours = updateCheckHours
        self.groupBy = groupBy
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case profile, region, terminal, ssh, overrides, hotkeys
        case refreshMinutes = "refresh_minutes"
        case syncSSHConfigOnRefresh = "sync_ssh_config_on_refresh"
        case manageSSHInclude = "manage_ssh_include"
        case healthyWithinHours = "healthy_within_hours"
        case updateChannel = "update_channel"
        case checkUpdatesOnLaunch = "check_updates_on_launch"
        case launchAtLogin = "launch_at_login"
        case tags
        case updateCheckHours = "update_check_hours"
        case groupBy = "group_by"
        case sources
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
    /// The log lives under ~/.hangar like everything else, so a reset or an
    /// uninstall takes it with them.
    public static var logDirectory: String {
        (home as NSString).appendingPathComponent("logs")
    }
    public static var logPath: String {
        (logDirectory as NSString).appendingPathComponent("hangar.log")
    }
    /// Written once the login probe has run, so it runs once on a machine and
    /// never again. An unprompted authentication attempt is the kind of thing
    /// that must not repeat on a timer.
    public static var loginProbedMarkerPath: String {
        (home as NSString).appendingPathComponent(".login-probed")
    }

    public static var onboardedMarkerPath: String {
        (home as NSString).appendingPathComponent(".setup-complete")
    }
    public static var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: onboardedMarkerPath)
    }
    public static func markOnboarded() {
        PrivateFile.write(Data(), to: onboardedMarkerPath)
    }

    /// The configured mapping, or the defaults when the config predates it.
    public var tagMapping: TagMapping { tags ?? .standard }

    /// The menubar levels, widest first. An empty list is a deliberate choice:
    /// a flat list of every host, which is the right answer for a small fleet.
    public var groupingKeys: [String] { groupBy ?? FleetGrouping.defaultLevels }

    /// Hosts the user brought themselves. A plain CSV rather than a database,
    /// so a script, a cron job or an inventory export can write it and the user
    /// can read what Hangar is going to do before it does it.
    public static var hostsFilePath: String {
        (home as NSString).appendingPathComponent("hosts.csv")
    }

    /// The sources to gather from, with every default already applied.
    public var sourceSettings: SourceSettings { sources ?? .standard }

    public static var sshIncludePath: String {
        NSString(string: "~/.ssh/config.d/hangar").expandingTildeInPath
    }

    public static func standard() -> HangarConfig {
        HangarConfig(
            profile: nil, region: nil, terminal: "iterm",
            ssh: SSHSettings(
                // No login unless the user picks one. Writing the macOS account
                // name was a guess, and because Hangar's Include sits at the top
                // of ~/.ssh/config and ssh_config is first-value-wins, that guess
                // outranked a `Host * / User ec2-user` the user had written
                // themselves. Saying nothing lets ssh do what it already does,
                // which is the same rule the key follows.
                user: nil,
                identityFile: nil,
                knownHostsFile: "~/.ssh/known_hosts.ec2",
                strictHostKeyChecking: "accept-new",
                extraOptions: [:]),
            overrides: [],
            hotkeys: [Hotkey(keys: "cmd+shift+h", title: "All hosts", filter: [:])],
            refreshMinutes: 30,
            syncSSHConfigOnRefresh: true,
            manageSSHInclude: true,
            healthyWithinHours: 24,
            updateChannel: "stable",
            checkUpdatesOnLaunch: true,
            launchAtLogin: false,
            tags: .standard,
            updateCheckHours: 24,
            groupBy: FleetGrouping.defaultLevels,
            sources: .standard)
    }

    /// Loads the config, writing a documented starter file on first run. A config
    /// that fails to parse is reported rather than silently replaced, so a typo
    /// never costs the user their settings.
    public static func load() throws -> HangarConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            PrivateFile.ensureDirectory(home)
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
        PrivateFile.ensureDirectory(home)
        guard PrivateFile.write(data, to: path) else {
            throw HangarError.malformedResponse("could not write \(path)")
        }
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
            if let v = override.identityAgent { result.identityAgent = v }
            if let v = override.identitiesOnly { result.identitiesOnly = v }
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
    /// The key names `tagValue(for:)` resolves instead of reading the tag, matched
    /// without regard to case.
    ///
    /// Beside the switch that implements them on purpose: a second list somewhere
    /// else would drift. Documentation and a test pin it; the marker on
    /// `hangar tags` deliberately does not use it, because being on this list is
    /// not the same as resolving to something other than the tag.
    static let resolvedKeyNames = ["name", "role", "env", "env_name", "product",
                                   "asg", "state", "id", "instance_id"]

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
