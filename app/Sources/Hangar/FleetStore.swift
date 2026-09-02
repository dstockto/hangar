import Foundation
import HangarCore

/// The app's single source of truth. Serves the on-disk cache immediately so the
/// panel opens instantly, then refreshes in the background. A refresh that fails
/// leaves the cached fleet in place and surfaces the reason, because a stale list
/// is far more useful than an empty one.
@MainActor
final class FleetStore: ObservableObject {
    struct Cache: Codable {
        var instances: [Instance]
        var region: String
        var fetchedAt: Date
    }

    enum Status: Equatable {
        case idle
        case refreshing
        case failed(String)
    }

    @Published private(set) var instances: [Instance] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var region: String = ""
    @Published private(set) var credentialSource: CredentialSource?
    @Published private(set) var lastSyncMessage: String?
    /// Advice for the current failure, derived from the profile that was tried.
    @Published private(set) var credentialAdvice: CredentialAdvice.Advice?

    /// Search-ready fleet, rebuilt only when the fleet or config changes.
    /// Everything the panel needs per keystroke is precomputed here.
    @Published private(set) var searchEntries: [SearchEntry] = []
    private var aliasByID: [String: String] = [:]

    private(set) var config: HangarConfig = .standard()
    private var managedHosts: Set<String> = []
    /// True only when ~/.ssh/config actually includes Hangar's file. Writing the
    /// file is not enough: without the Include line ssh cannot resolve a single
    /// alias, and handing one to a terminal produces an instant failure.
    @Published private(set) var sshAliasesActive = false

    init() {
        reloadConfig()
        loadCache()
        refreshManagedHosts()
        rebuildIndex()
    }

    /// Builds the alias table once and keeps it. It used to be derived per row
    /// inside the filter loop, which meant sorting all 249 entries for every
    /// instance on every keystroke.
    private func rebuildIndex() {
        let writer = SSHConfigWriter(config: config)
        let entries = writer.entries(for: instances)
        aliasByID = [:]
        aliasByID.reserveCapacity(entries.count)
        for entry in entries {
            aliasByID[entry.instance.id] = entry.aliases.first
        }
        searchEntries = instances
            .map { SearchEntry(instance: $0, alias: aliasByID[$0.id] ?? $0.aliasStem) }
            .sorted { ($0.instance.product, $0.instance.env, $0.alias)
                        < ($1.instance.product, $1.instance.env, $1.alias) }
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        let minutes = Double(config.refreshMinutes ?? 30)
        return Date().timeIntervalSince(fetchedAt) > minutes * 60
    }

    /// Healthy means the cache was refreshed inside the configured window, so the
    /// fleet on screen can be trusted. Drives the menubar health tint.
    var isHealthy: Bool {
        guard let fetchedAt, !instances.isEmpty else { return false }
        if case .failed = status { return false }
        let hours = Double(config.healthyWithinHours ?? 24)
        return Date().timeIntervalSince(fetchedAt) < hours * 3600
    }

    var staleDescription: String? {
        guard let fetchedAt else { return "never refreshed" }
        let elapsed = Date().timeIntervalSince(fetchedAt)
        if elapsed < 90 { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: fetchedAt, relativeTo: Date())
    }

    func reloadConfig() {
        do {
            let previous = config
            config = try HangarConfig.load()
            if !instances.isEmpty, !sameSSHShape(previous, config) { rebuildIndex() }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Only ssh-affecting settings change aliases, so avoid rebuilding the index
    /// when something cosmetic such as the terminal choice changes.
    private func sameSSHShape(_ a: HangarConfig, _ b: HangarConfig) -> Bool {
        a.ssh?.user == b.ssh?.user
            && a.ssh?.identityFile == b.ssh?.identityFile
            && (a.overrides?.count ?? 0) == (b.overrides?.count ?? 0)
    }

    func isManaged(_ host: String) -> Bool { managedHosts.contains(host) }

    private func refreshManagedHosts() {
        managedHosts = []
        sshAliasesActive = SSHConfigWriter.includeLinePresent()
        guard sshAliasesActive,
              let text = try? String(contentsOfFile: HangarConfig.sshIncludePath,
                                     encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Host ") else { continue }
            for name in trimmed.dropFirst(5).split(separator: " ") {
                managedHosts.insert(String(name))
            }
        }
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = FileManager.default.contents(atPath: HangarConfig.cachePath),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        // Re-normalized on load: the mapping may have changed since the cache
        // was written, and waiting for a refresh would show stale grouping.
        instances = config.tagMapping.normalize(cache.instances)
        region = cache.region
        fetchedAt = cache.fetchedAt
        rebuildIndex()
    }

    private func saveCache() {
        let cache = Cache(instances: instances, region: region, fetchedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        // The cache is the whole fleet: ids, private addresses, every tag. It gets
        // the same 0600 the config and the ssh include get, from creation.
        PrivateFile.write(data, to: HangarConfig.cachePath)
    }

    // MARK: - Refresh

    func refresh() async {
        guard status != .refreshing else { return }
        status = .refreshing
        reloadConfig()
        // Read before resolving: when resolution fails we still need to know what
        // kind of profile it was to say anything useful about why.
        let attempted = try? AWSConfigFiles.load().profile(named: config.profile)
        do {
            let resolved = try await CredentialResolver.resolve(profile: config.profile)
            let queryRegion = config.region ?? resolved.region
            let ec2 = EC2(credentials: resolved.credentials, region: queryRegion)
            let fetched = try await ec2.describeInstances(filters: [
                EC2.Filter(name: "instance-state-name",
                           values: ["pending", "running", "stopping", "stopped"])
            ])
            // Tags are mapped to Hangar's canonical keys here, so every screen
            // below this line reads "product" and "env" regardless of how the
            // fleet spells them.
            instances = config.tagMapping.normalize(fetched)
            region = queryRegion
            fetchedAt = Date()
            rebuildIndex()
            credentialSource = resolved.source
            credentialAdvice = nil
            status = .idle
            saveCache()
            if config.syncSSHConfigOnRefresh ?? true {
                syncSSHConfig(announce: false)
            }
        } catch {
            let advice = CredentialAdvice.forFailure(error, profile: attempted)
            credentialAdvice = advice
            status = .failed(advice.message)
        }
    }

    /// Errors that are not about credentials, shown as they came.
    static func presentable(_ error: Error) -> String {
        error.localizedDescription
    }

    func syncSSHConfig(announce: Bool = true) {
        guard !instances.isEmpty else {
            lastSyncMessage = "No hosts to write. Refresh the fleet first."
            return
        }
        do {
            let writer = SSHConfigWriter(config: config)
            let result = try writer.sync(instances: instances, region: region)
            refreshManagedHosts()
            if !result.omittedHosts.isEmpty {
                // Silence here would look like the hosts had been terminated.
                lastSyncMessage = "\(result.omittedHosts.count) host(s) skipped: "
                    + "an unusable hostname tag. First: \(result.omittedHosts[0])"
            } else if announce || result.includeLineNeeded {
                lastSyncMessage = result.includeLineNeeded
                    ? "SSH config updated: ~/.ssh/config.d/hangar. Add the Include line to ~/.ssh/config."
                    : "SSH config updated: ~/.ssh/config.d/hangar"
            }
        } catch {
            lastSyncMessage = FleetStore.presentable(error)
        }
    }

    // MARK: - Querying

    /// Instances matching a hotkey's filter, e.g. {"env": "prod"}.
    func instances(matching filter: [String: String]?) -> [Instance] {
        guard let filter, !filter.isEmpty else { return instances }
        return instances.filter { instance in
            filter.allSatisfy { key, pattern in
                HangarConfig.wildcard(pattern, instance.tagValue(for: key))
            }
        }
    }

    /// Search-ready entries for a hotkey's filter.
    func entries(matching filter: [String: String]?) -> [SearchEntry] {
        guard let filter, !filter.isEmpty else { return searchEntries }
        return searchEntries.filter { entry in
            filter.allSatisfy { key, pattern in
                HangarConfig.wildcard(pattern, entry.instance.tagValue(for: key))
            }
        }
    }

    // MARK: - Per-host ssh overrides

    /// The scopes a per-host edit can be saved at. Users usually discover a wrong
    /// login on one box and need it for its whole class, so the broader scopes are
    /// offered alongside the single host.
    enum OverrideScope: Equatable {
        case host(Instance)
        case roleInEnvironment(Instance)
        case productAndEnvironment(Instance)
        case product(Instance)

        var match: [String: String] {
            switch self {
            case .host(let i):
                return ["id": i.id]
            case .roleInEnvironment(let i):
                return ["product": i.product, "env": i.env, "name": i.role]
                    .filter { !$0.value.isEmpty }
            case .productAndEnvironment(let i):
                return ["product": i.product, "env": i.env].filter { !$0.value.isEmpty }
            case .product(let i):
                return ["product": i.product].filter { !$0.value.isEmpty }
            }
        }

        var label: String {
            switch self {
            case .host:
                return "This host only"
            case .roleInEnvironment(let i):
                return "All \(i.role) in \(i.product) \(i.env)"
            case .productAndEnvironment(let i):
                return "All \(i.product) \(i.env) hosts"
            case .product(let i):
                return "All \(i.product) hosts"
            }
        }

        static func all(for instance: Instance) -> [OverrideScope] {
            var scopes: [OverrideScope] = [.host(instance)]
            if !instance.role.isEmpty && !instance.env.isEmpty {
                scopes.append(.roleInEnvironment(instance))
            }
            if !instance.env.isEmpty { scopes.append(.productAndEnvironment(instance)) }
            if !instance.product.isEmpty { scopes.append(.product(instance)) }
            return scopes
        }
    }

    /// What ssh itself will use for a host right now, which is the honest starting
    /// point for an edit: it accounts for the user's own ~/.ssh/config too.
    func effectiveSSHSettings(for instance: Instance) -> (user: String?, identityFile: String?) {
        let target = alias(for: instance).flatMap { isManaged($0) ? $0 : nil }
            ?? instance.host ?? instance.id
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHProbe.effectiveSettingsArguments(target: target)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var user: String?
        var identity: String?
        for line in (String(data: data, encoding: .utf8) ?? "").components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "user", user == nil { user = parts[1] }
            if parts[0] == "identityfile", identity == nil { identity = parts[1] }
        }
        return (user, identity)
    }

    /// Saves the edit as a config override, regenerates the ssh include, and
    /// returns what to tell the user.
    func saveOverride(scope: OverrideScope, user: String?, identityFile: String?) -> String {
        var updated = config
        updated.setOverride(match: scope.match, user: user, identityFile: identityFile)
        do {
            try HangarConfig.write(updated)
        } catch {
            return "Could not write \(HangarConfig.path)"
        }
        config = updated
        rebuildIndex()
        syncSSHConfig(announce: false)
        if user == nil && identityFile == nil {
            return "Override removed for \(scope.label.lowercased())"
        }
        return "SSH config updated: ~/.ssh/config.d/hangar"
    }

    func existingOverride(scope: OverrideScope) -> HangarConfig.Override? {
        config.override(for: scope.match)
    }

    /// Probes candidate logins in parallel and returns the first that authenticates.
    /// Parallel because ten sequential six-second attempts is a minute of waiting.
    nonisolated static func detectLogin(host: String, identityFile: String?,
                                        candidates: [String]) async -> String? {
        await withTaskGroup(of: (String, Bool).self) { group in
            for candidate in candidates {
                group.addTask {
                    let result = testConnection(host: host, user: candidate,
                                                identityFile: identityFile)
                    return (candidate, result.ok)
                }
            }
            var winner: String?
            for await (candidate, ok) in group where ok {
                // Candidates are in preference order, so keep the earliest success.
                if let current = winner,
                   let a = candidates.firstIndex(of: candidate),
                   let b = candidates.firstIndex(of: current), a >= b { continue }
                winner = candidate
            }
            return winner
        }
    }

    /// Non-interactive auth check, so a wrong login is discovered here rather than
    /// in a terminal. Never prompts and never runs a remote command beyond `true`.
    nonisolated static func testConnection(host: String, user: String?,
                                           identityFile: String?) -> (ok: Bool, detail: String) {
        let arguments = SSHProbe.arguments(host: host, user: user,
                                           identityFile: identityFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return (false, "could not run ssh") }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return (true, "Authenticated") }
        let text = (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "exit \(process.terminationStatus)"
        return (false, text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Approved status strings

    /// "248 hosts · us-west-2", per the brand kit's status format.
    var fleetSummary: String {
        let count = instances.count
        return region.isEmpty ? "\(count) hosts" : "\(count) hosts · \(region)"
    }

    /// The credential source split into a label and the literal identifier it
    /// names, so the identifier can be shown in monospace like every other
    /// copyable value in the UI.
    var credentialDescription: (label: String, literal: String?)? {
        switch credentialSource {
        case .none:                        return nil
        case .environment:                 return ("Environment credentials", nil)
        case .sso(let profile):            return ("SSO profile", profile)
        case .staticKeys(let profile):     return ("Static keys, profile", profile)
        case .assumedRole(_, let arn):     return ("Assuming role", arn)
        case .credentialProcess(let p):    return ("credential_process, profile", p)
        }
    }

    /// "Cache updated 2 min ago", or nil while the cache is fresh.
    var cacheAgeDescription: String? {
        guard let fetchedAt else { return "Cache never updated" }
        let elapsed = Date().timeIntervalSince(fetchedAt)
        if elapsed < 90 { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = elapsed < 3600 ? [.minute] : (elapsed < 86400 ? [.hour] : [.day])
        formatter.maximumUnitCount = 1
        let age = formatter.string(from: elapsed) ?? ""
        return "Cache updated \(age) ago"
    }

    /// The ssh alias Hangar wrote for an instance, when it wrote one.
    func alias(for instance: Instance) -> String? { aliasByID[instance.id] }

    func sshTarget(for instance: Instance) -> (command: String, target: String) {
        let alias = aliasByID[instance.id]
        let host = instance.host ?? instance.privateIP ?? instance.id
        if let alias, isManaged(alias) {
            return (Launcher.sshCommand(for: alias, settings: nil, managedByConfig: true), alias)
        }
        let settings = config.sshSettings(for: instance)
        return (Launcher.sshCommand(for: host, settings: settings, managedByConfig: false), host)
    }
}
