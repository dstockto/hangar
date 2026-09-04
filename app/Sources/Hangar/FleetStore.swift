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
        /// The fleet's real tag keys, captured before normalization. Persisted so
        /// the setup screen can offer them without waiting for a refresh.
        var tagCatalog: TagCatalog?
        /// A short history of host counts, one per successful refresh, so the
        /// dashboard can say "223 to 209 since 14:02" rather than only what is
        /// true this second. Optional, because a cache written before this
        /// existed has to keep decoding.
        var history: [Sample]?
    }

    struct Sample: Codable, Equatable, Sendable {
        var at: Date
        var hosts: Int
    }

    /// About a day and a half at the default refresh, and a few hundred bytes.
    static let historyLimit = 60

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
    /// Which tag keys this fleet actually uses, for the setup screen's picker.
    @Published private(set) var tagCatalog: TagCatalog = .empty
    /// Host counts over the last few dozen refreshes, oldest first.
    @Published private(set) var history: [Sample] = []
    /// What each source produced on the last refresh, in priority order.
    @Published private(set) var sourceReports: [SourceReport] = []
    /// The ssh agents on this machine and what they are holding. Detected on
    /// demand rather than on every refresh: it runs a process, and the fleet
    /// refreshing on a timer is not a reason to poke at someone's vault.
    @Published private(set) var agents: [SSHAgent] = []
    /// So the launch check and the setup screen do not both run ssh-add.
    private var hasCheckedAgents = false

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
        // Hosts Hangar deliberately does not write still have a name, and it is
        // the one ssh already resolves. Leaving them out of the table would show
        // an imported host under a slug that connects to nothing.
        for instance in instances where !instance.isWrittenToSSHConfig {
            aliasByID[instance.id] = instance.aliasStem
        }
        searchEntries = instances
            .map { SearchEntry(instance: $0, alias: aliasByID[$0.id] ?? $0.aliasStem) }
            .sorted { FleetStore.sortKey($0) < FleetStore.sortKey($1) }
    }

    /// Product, environment, alias, with anything carrying no product sent to the
    /// end rather than the front.
    ///
    /// An empty string sorts first, so an untagged group used to open the panel.
    /// That was survivable when untagged meant a handful of forgotten EC2 boxes.
    /// It is not now: a few git hosts in someone's ssh config would sit above
    /// their whole fleet, every time.
    static func sortKey(_ entry: SearchEntry) -> (Int, String, String, String) {
        (entry.instance.product.isEmpty ? 1 : 0,
         entry.instance.product, entry.instance.env, entry.alias)
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
        tagCatalog = cache.tagCatalog ?? .empty
        history = cache.history ?? []
        rebuildIndex()
    }

    private func saveCache() {
        let cache = Cache(instances: instances, region: region, fetchedAt: Date(),
                          tagCatalog: tagCatalog, history: history)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        // The cache is the whole fleet: ids, private addresses, every tag. It gets
        // the same 0600 the config and the ssh include get, from creation.
        PrivateFile.write(data, to: HangarConfig.cachePath)
    }

    // MARK: - Refresh

    /// Gathers every enabled source, merges them, and reports each one.
    ///
    /// Local sources run first and without a network, so an SRE with no AWS
    /// permission at all has a fleet before AWS is even asked. That ordering is
    /// the feature: a denied `DescribeInstances` stops being a dead end and
    /// becomes one line in a list of sources, most of which worked.
    func refresh() async {
        guard status != .refreshing else { return }
        status = .refreshing
        let started = Date()
        Log.info(.fleet, "refresh started")
        reloadConfig()

        let settings = config.sourceSettings
        var groups: [HostSource: [Instance]] = [:]
        var reports: [SourceReport] = []

        // Local first. Neither needs a credential, so neither can be held up by
        // one that is expired.
        if settings.wantsSSHConfig {
            let imported = SSHConfigImport.load()
            groups[.sshConfig] = imported.hosts
            reports.append(SourceReport(source: .sshConfig, hosts: imported.hosts.count,
                                        skipped: imported.skipped))
        } else {
            reports.append(.off(.sshConfig))
        }

        if settings.wantsHostsFile {
            let file = HostsFile.load()
            groups[.hostsFile] = file.hosts
            reports.append(SourceReport(source: .hostsFile, hosts: file.hosts.count,
                                        skipped: file.skipped))
        } else {
            reports.append(.off(.hostsFile))
        }

        // Then AWS, which may fail without costing the user the hosts above.
        let awsFiles = AWSConfigFiles.load()
        let attempted = try? awsFiles.profile(named: config.profile)
        var awsFailure: Error?
        var queryRegion = region
        if settings.wantsEC2 || settings.wantsSSMAlways {
            do {
                let resolved = try await CredentialResolver.resolve(profile: config.profile)
                queryRegion = config.region ?? resolved.region
                credentialSource = resolved.source
                credentialAdvice = nil
                Log.info(.credentials, "credentials resolved",
                         ["source": resolved.source.label])

                var ec2Denied = false
                if settings.wantsEC2 {
                    do {
                        let ec2 = EC2(credentials: resolved.credentials, region: queryRegion)
                        let fetched = try await ec2.describeInstances(filters: [
                            EC2.Filter(name: "instance-state-name",
                                       values: ["pending", "running", "stopping", "stopped"])
                        ])
                        groups[.ec2] = fetched
                        reports.append(SourceReport(source: .ec2, hosts: fetched.count))
                    } catch {
                        ec2Denied = SSM.isAuthorizationFailure(error)
                        awsFailure = error
                        reports.append(SourceReport(
                            source: .ec2, problem: FleetStore.presentable(error)))
                        Log.warning(.fleet, "ec2 source failed",
                                    ["error": error.localizedDescription])
                    }
                } else {
                    reports.append(.off(.ec2))
                }

                // Only when EC2 said no, or when it was asked for outright. An
                // account with EC2 read pays nothing for this.
                if settings.wantsSSMAlways || (ec2Denied && settings.wantsSSMAfterFailure) {
                    do {
                        let ssm = SSM(credentials: resolved.credentials, region: queryRegion)
                        let fetched = try await ssm.describeInstanceInformation()
                        groups[.ssm] = fetched
                        reports.append(SourceReport(source: .ssm, hosts: fetched.count))
                        if !fetched.isEmpty { awsFailure = nil }
                    } catch {
                        reports.append(SourceReport(
                            source: .ssm, problem: FleetStore.presentable(error)))
                        Log.warning(.fleet, "ssm source failed",
                                    ["error": error.localizedDescription])
                    }
                } else {
                    reports.append(.off(.ssm))
                }
            } catch {
                // Credentials themselves failed, so neither AWS source ran.
                awsFailure = error
                let advice = CredentialAdvice.forFailure(
                    error, profile: attempted,
                    alternatives: awsFiles.profileSummaries
                        .filter(\.isUsable).map(\.name))
                credentialAdvice = advice
                reports.append(SourceReport(source: .ec2, problem: advice.message))
                reports.append(.off(.ssm))
            }
        } else {
            reports.append(.off(.ec2))
            reports.append(.off(.ssm))
        }

        let merged = FleetMerge.merge(groups)
        sourceReports = reports.sorted {
            (FleetMerge.priority.firstIndex(of: $0.source) ?? 0)
                < (FleetMerge.priority.firstIndex(of: $1.source) ?? 0)
        }

        // Nothing from anywhere is the only real failure. Anything else is a
        // fleet with a note attached, and a fleet beats an error page.
        guard !merged.instances.isEmpty else {
            let message = awsFailure.map {
                CredentialAdvice.forFailure(
                    $0, profile: attempted,
                    alternatives: awsFiles.profileSummaries
                        .filter(\.isUsable).map(\.name)).message
            } ?? "No hosts from any source."
            status = .failed(message)
            Log.error(.fleet, "refresh found nothing",
                      ["ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
            return
        }

        // Catalogued before normalization, which adds the canonical keys whether
        // the fleet uses them or not.
        tagCatalog = TagCatalog.discover(from: merged.instances)
        // Tags are mapped to Hangar's canonical keys here, so every screen below
        // this line reads "product" and "env" regardless of how the fleet, or the
        // spreadsheet, or the ssh config, spells them.
        instances = config.tagMapping.normalize(merged.instances)
        region = queryRegion
        fetchedAt = Date()
        rebuildIndex()
        history.append(Sample(at: Date(), hosts: instances.count))
        if history.count > FleetStore.historyLimit {
            history.removeFirst(history.count - FleetStore.historyLimit)
        }
        status = .idle
        Log.info(.fleet, "refresh finished",
                 ["hosts": "\(instances.count)", "region": queryRegion,
                  "sources": "\(sourceReports.filter { $0.hosts > 0 }.count)",
                  "duplicates": "\(merged.duplicates)",
                  "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"])
        saveCache()
        if config.syncSSHConfigOnRefresh ?? true {
            syncSSHConfig(announce: false)
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
        // A fleet made entirely of imported hosts is a fleet Hangar writes
        // nothing for, and that is correct rather than a failure.
        guard instances.contains(where: { $0.isWrittenToSSHConfig }) else {
            refreshManagedHosts()
            if announce {
                lastSyncMessage = "Nothing to write: every host is already in "
                    + "~/.ssh/config, and Hangar leaves those alone."
            }
            return
        }
        do {
            let writer = SSHConfigWriter(config: config)
            // The Include line comes with the aliases unless the user has said
            // they manage it themselves. Writing aliases no terminal can see is
            // not a feature with an optional extra step.
            let result = try writer.sync(instances: instances,
                                         region: region.isEmpty ? "local sources" : region,
                                         ensuringInclude: config.manageSSHInclude ?? true)
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
        } catch let error as HangarError {
            lastSyncMessage = FleetStore.presentable(error)
            Log.error(.ssh, "sync failed", ["error": error.localizedDescription])
        } catch {
            // An Include that cannot be written does not fail the sync: the
            // aliases are on disk and Hangar itself connects either way.
            let text = FleetStore.presentable(error)
            lastSyncMessage = SSHConfigWriter.includeLinePresent()
                ? text
                : "Aliases written. The Include line could not be added to "
                    + "~/.ssh/config: \(text)"
            Log.error(.ssh, "include line could not be added", ["error": text])
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
        guard let result = try? ProcessRunner.run(
            "/usr/bin/ssh", SSHProbe.effectiveSettingsArguments(target: target),
            timeout: 10) else { return (nil, nil) }
        var user: String?
        var identity: String?
        for line in result.out.components(separatedBy: .newlines) {
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

    // MARK: - AWS profile

    /// Every profile the picker can offer, with how each one authenticates.
    var profileSummaries: [ProfileSummary] { AWSConfigFiles.load().profileSummaries }

    /// The profile in effect, which is not always the one in the config: nothing
    /// is set until the user picks one. Nil when exported keys win outright.
    var activeProfileName: String? {
        AWSConfigFiles.activeProfileName(requested: config.profile)
    }

    /// Picks the profile the EC2 and Systems Manager sources authenticate with.
    /// Nil hands the choice back to AWS_PROFILE and default.
    @discardableResult
    func useProfile(_ name: String?) -> String {
        var updated = config
        updated.profile = name
        do {
            try HangarConfig.write(updated)
        } catch {
            return "Could not write \(HangarConfig.path)"
        }
        config = updated
        guard let name else {
            let automatic = activeProfileName
            return automatic == nil
                ? "Using the credentials in your environment"
                : "Using \(automatic ?? "") again, the AWS default"
        }
        return "AWS sources now use profile \(name)"
    }

    // MARK: - Terminal

    /// The terminal sessions open in. One reading of the config value, so the
    /// panel, the menubar and the setup check cannot disagree about it.
    var terminal: TerminalChoice { TerminalChoice.from(config.terminal) }

    /// Picks the terminal Hangar hands sessions to.
    @discardableResult
    func useTerminal(_ choice: TerminalChoice) -> String {
        var updated = config
        updated.terminal = choice.rawValue
        do {
            try HangarConfig.write(updated)
        } catch {
            return "Could not write \(HangarConfig.path)"
        }
        config = updated
        return "Sessions now open in \(choice.displayName)"
    }

    // MARK: - Tag mapping

    /// Points one idea at one of the fleet's own tag keys, then rebuilds
    /// everything downstream of it: the grouping, the aliases, and the ssh
    /// include. No refresh needed, because the tags are already in hand.
    func useTagKey(_ key: String?, for concept: TagCatalog.Concept) -> String {
        var updated = config
        var mapping = updated.tagMapping
        mapping.use(key, for: concept)
        updated.tags = mapping
        do {
            try HangarConfig.write(updated)
        } catch {
            return "Could not write \(HangarConfig.path)"
        }
        config = updated
        instances = mapping.normalize(instances)
        rebuildIndex()
        if config.syncSSHConfigOnRefresh ?? true { syncSSHConfig(announce: false) }
        guard let key, !key.isEmpty else {
            return "\(concept.title) is no longer read from a tag"
        }
        return "\(concept.title) now reads the \(key) tag"
    }

    /// What the current mapping resolves for each idea against this fleet.
    func resolvedTagKey(for concept: TagCatalog.Concept) -> String? {
        config.tagMapping.resolvedKey(for: concept, in: tagCatalog)
    }

    /// Drops everything in memory and reloads from whatever is left on disk.
    /// Called after a reset, so a cleared cache is actually forgotten rather
    /// than lingering in the published properties until the next fetch.
    func reloadAfterReset() {
        instances = []
        searchEntries = []
        aliasByID = [:]
        tagCatalog = .empty
        fetchedAt = nil
        region = ""
        credentialSource = nil
        credentialAdvice = nil
        lastSyncMessage = nil
        status = .idle
        config = .standard()
        reloadConfig()
        loadCache()
        refreshManagedHosts()
        rebuildIndex()
    }

    // MARK: - Menu levels

    /// The menubar levels, in order.
    var groupingKeys: [String] { config.groupingKeys }

    /// Replaces the level list wholesale. Add, remove and reorder all come
    /// through here, so there is one place that writes and rebuilds.
    @discardableResult
    func setGroupingKeys(_ keys: [String]) -> String {
        var updated = config
        updated.groupBy = keys
        do {
            try HangarConfig.write(updated)
        } catch {
            return "Could not write \(HangarConfig.path)"
        }
        config = updated
        rebuildIndex()
        if keys.isEmpty { return "The menu now lists every host flat" }
        let produced = FleetGrouping.depth(instances, groupBy: keys)
        if produced < keys.count {
            return "\(keys.joined(separator: " \u{203A} ")). "
                + "\(keys.count - produced) of them no host carries yet."
        }
        return "Menu levels: \(keys.joined(separator: " \u{203A} "))"
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
        // ConnectTimeout covers the connect, not a ProxyCommand or a resolver
        // that never returns, so the deadline sits outside ssh as well as in it.
        guard let result = try? ProcessRunner.run("/usr/bin/ssh", arguments, timeout: 30) else {
            return (false, "ssh did not answer in time")
        }
        if result.status == 0 { return (true, "Authenticated") }
        let text = result.err
            .components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "exit \(result.status)"
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

    // MARK: - Keys

    /// Looks for an ssh agent holding the key.
    ///
    /// Runs a process, so it is called when the setup screen asks rather than on
    /// the refresh timer: a fleet refreshing every half hour is not a reason to
    /// keep poking at someone's vault.
    func detectAgents() {
        hasCheckedAgents = true
        agents = KeySource.detectAgents()
        for agent in agents {
            Log.info(.ssh, "ssh agent found",
                     ["agent": agent.kind.rawValue, "keys": "\(agent.keys.count)"])
        }
    }

    /// True when Hangar has no opinion about keys yet, which is the only state in
    /// which it is allowed to form one on the user's behalf.
    var hasKeyPreference: Bool {
        config.ssh?.identityAgent?.isEmpty == false || config.ssh?.identityFile?.isEmpty == false
    }

    /// Adopts the only key there is, once, when the user has expressed no
    /// preference. Returns what to tell them, or nil when nothing was done.
    ///
    /// This used to live in the setup window, which opens on first run only, so
    /// everyone upgrading from an earlier version kept the old behaviour until
    /// they happened to open Setup Check. A feature nobody can find is not a
    /// feature. It still runs at most once per launch, because it starts a
    /// process and a fleet refreshing on a timer is no reason to keep poking at
    /// somebody's vault.
    func adoptAgentKeyIfUnset() -> String? {
        guard !hasKeyPreference, !hasCheckedAgents else { return nil }
        hasCheckedAgents = true
        detectAgents()
        guard let agent = agents.first(where: { $0.keys.count == 1 }),
              let key = agent.keys.first,
              adopt(agent: agent, key: key) != nil else { return nil }
        return "\(key.title). The private key stays in \(agent.name)."
    }

    // MARK: - Learning the login

    /// Works out the ssh login once, by asking one host, and records it.
    ///
    /// Only when the user has not chosen a login, only against a single running
    /// host, only up to `SSHLogin.probeLimit` attempts, and only once per machine.
    /// Every one of those bounds is deliberate: this is an unprompted outbound
    /// authentication attempt, and a fleet-wide or repeating version of it is how
    /// you get an SRE's laptop banned by their own fail2ban.
    func learnLoginIfUnset() async -> String? {
        guard (config.ssh?.user ?? "").isEmpty else { return nil }
        var state = LoginProbeState.load()
        guard state.shouldRun else { return nil }

        // Hosts this machine has connected to before are the only evidence of
        // reachability available, and on a fleet behind a VPN they are the
        // difference between a probe that can answer and one that cannot.
        let known = SSHLogin.knownHostnames(paths: [
            config.ssh?.knownHostsFile ?? "~/.ssh/known_hosts.ec2",
            "~/.ssh/known_hosts",
        ])
        let hosts = SSHLogin.probeCandidates(from: instances, preferring: known)
        guard !hosts.isEmpty else { return nil }

        // Counted before the attempt, so a probe that crashes or is killed does
        // not come back on every launch forever.
        state.attempts += 1
        state.save()

        let targets = hosts.map { alias(for: $0) ?? $0.host ?? $0.id }
        let order = SSHLogin.probeOrder(platform: hosts[0].platform,
                                        effective: config.ssh?.user)
        Log.info(.ssh, "learning the ssh login",
                 ["hosts": "\(targets.count)", "logins": "\(order.count)",
                  "attempt": "\(state.attempts)"])

        let outcome = await Task.detached(priority: .utility) {
            () -> (login: String?, reached: Bool) in
            var reached = false
            for target in targets {
                for login in order {
                    let result = FleetStore.testConnection(host: target, user: login,
                                                           identityFile: nil)
                    if result.ok { return (login, true) }
                    // A host that cannot be reached has no opinion about logins,
                    // so stop asking it and move to the next one.
                    if SSHLogin.isUnreachable(result.detail) { break }
                    reached = true
                }
            }
            return (nil, reached)
        }.value

        // Only a host that actually answered settles the question. All-unreachable
        // means try again next launch, which is the whole point of the change.
        if outcome.reached {
            state.settled = true
            state.save()
        } else {
            Log.info(.ssh, "no host answered; will try again next launch",
                     ["attempt": "\(state.attempts)"])
        }

        guard let found = outcome.login else {
            if outcome.reached { Log.info(.ssh, "no login authenticated; leaving it to ssh") }
            return nil
        }
        var updated = config
        var ssh = updated.ssh ?? HangarConfig.SSHSettings()
        ssh.user = found
        updated.ssh = ssh
        guard (try? HangarConfig.write(updated)) != nil else { return nil }
        config = updated
        rebuildIndex()
        syncSSHConfig(announce: false)
        Log.info(.ssh, "ssh login learned", ["user": found])
        return found
    }

    /// Pins one agent key for every host. The public half is written under
    /// ~/.hangar/keys and named by IdentityFile; the private half is never read,
    /// asked for, or stored.
    @discardableResult
    func adopt(agent: SSHAgent, key: AgentKey) -> String? {
        guard let path = KeySource.materialize(key) else {
            lastSyncMessage = "Could not write the public key under ~/.hangar/keys."
            return nil
        }
        var updated = config
        var ssh = updated.ssh ?? HangarConfig.SSHSettings(user: NSUserName())
        ssh.identityAgent = agent.socket
        ssh.identityFile = path
        ssh.identitiesOnly = true
        updated.ssh = ssh
        do {
            try HangarConfig.write(updated)
            config = updated
            rebuildIndex()
            syncSSHConfig(announce: false)
            Log.info(.ssh, "agent key adopted",
                     ["agent": agent.kind.rawValue, "key": Redact.host(key.title)])
            // A key that is no longer in the vault leaves an IdentityFile pointing
            // at a key nobody has, which fails at connect time rather than here.
            for stale in KeySource.staleKeyFiles(keeping: agent.keys) {
                try? FileManager.default.removeItem(atPath: stale)
            }
            return path
        } catch {
            lastSyncMessage = FleetStore.presentable(error)
            return nil
        }
    }

    /// Stops pinning a key, which puts ssh back to deciding for itself.
    func clearKeyPreference() {
        var updated = config
        var ssh = updated.ssh ?? HangarConfig.SSHSettings(user: NSUserName())
        ssh.identityAgent = nil
        ssh.identityFile = nil
        ssh.identitiesOnly = nil
        updated.ssh = ssh
        guard (try? HangarConfig.write(updated)) != nil else { return }
        config = updated
        syncSSHConfig(announce: false)
    }

    /// Pins a key file rather than an agent key.
    func adopt(keyFile path: String) {
        var updated = config
        var ssh = updated.ssh ?? HangarConfig.SSHSettings(user: NSUserName())
        ssh.identityAgent = nil
        ssh.identityFile = path
        ssh.identitiesOnly = true
        updated.ssh = ssh
        guard (try? HangarConfig.write(updated)) != nil else { return }
        config = updated
        syncSSHConfig(announce: false)
    }

    // MARK: - Hosts file

    /// Copies a CSV into ~/.hangar/hosts.csv and refreshes. Importing is a file
    /// copy and nothing else, so what Hangar reads is a file the user can open.
    func importHosts(from url: URL) async -> String {
        do {
            let result = try HostsFile.install(from: url)
            await refresh()
            let skipped = result.skipped.isEmpty
                ? "" : ", \(result.skipped.count) row(s) skipped"
            return "Imported \(result.hosts.count) hosts from "
                + "\(url.lastPathComponent)\(skipped)"
        } catch {
            return FleetStore.presentable(error)
        }
    }

    /// Writes the example CSV so there is something to edit rather than a format
    /// to guess at.
    func writeExampleHostsFile() -> Bool {
        guard !FileManager.default.fileExists(atPath: HangarConfig.hostsFilePath) else {
            return true
        }
        return PrivateFile.write(Data((HostsFile.example + "\n").utf8),
                                 to: HangarConfig.hostsFilePath)
    }

    /// Hosts Hangar writes into its own include, which is not the size of the
    /// fleet: an imported host is launched from the user's file, not ours.
    var writtenHostCount: Int {
        SSHConfigWriter(config: config).entries(for: instances).count
    }

    var importedHostCount: Int {
        instances.count { !$0.isWrittenToSSHConfig }
    }

    /// The ssh alias Hangar wrote for an instance, when it wrote one.
    func alias(for instance: Instance) -> String? { aliasByID[instance.id] }

    func sshTarget(for instance: Instance) -> (command: String, target: String) {
        let alias = aliasByID[instance.id]
        let host = instance.host ?? instance.privateIP ?? instance.id
        // A host imported from the user's own config is already resolvable, so
        // it gets a bare `ssh <alias>` and keeps whatever their file says about
        // it: the port, the ProxyJump, the login. Spelling our own guesses out
        // on the command line would override the file we imported it from.
        if let alias, isManaged(alias) || !instance.isWrittenToSSHConfig {
            return (Launcher.sshCommand(for: alias, settings: nil, managedByConfig: true), alias)
        }
        let settings = config.sshSettings(for: instance)
        return (Launcher.sshCommand(for: host, settings: settings, managedByConfig: false), host)
    }
}
