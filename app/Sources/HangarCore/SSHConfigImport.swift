import Foundation

/// Reads the hosts the user already has in `~/.ssh/config`.
///
/// Nothing here is written back. That is the whole design of the import: these
/// hosts are already resolvable by ssh, so Hangar indexes them for search,
/// grouping and launch and stays out of the file. Writing them into Hangar's own
/// include would put a second definition *above* the user's, and ssh_config is
/// first-match-wins, so Hangar would quietly outrank a file they wrote by hand.
public enum SSHConfigImport {

    public struct Result: Sendable {
        public var hosts: [Instance]
        /// Blocks that were read and not used, already worded for a person.
        public var skipped: [String]
    }

    /// How deep `Include` is followed. An include loop is a plausible hand-edit,
    /// and a visited set plus a cap is cheaper than trusting the file.
    static let maxIncludeDepth = 8

    /// Forges whose `Host` entry is a git remote credential rather than a machine.
    ///
    /// Almost every developer's `~/.ssh/config` has two or three of these, and
    /// none of them is a host: `ssh git@github.com` prints a greeting and exits.
    /// Importing them puts rows in a host launcher that can never be launched,
    /// and they sort to the top because they carry no product.
    public static let gitServiceHosts: Set<String> = [
        "github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "gitea.com",
        "git.sr.ht", "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
        "source.developers.google.com", "git.launchpad.net", "git.savannah.gnu.org",
        "altssh.bitbucket.org", "ssh.github.com",
    ]

    /// `User git` is the workhorse rule here, not the list. Every self-hosted
    /// GitLab, Gitea and Forgejo is reached as `git@`, and nobody shells into a
    /// machine as `git`. The list covers the entries that omit `User` because it
    /// is already in the remote URL.
    public static func isGitService(alias: String, hostName: String?,
                                    user: String?) -> Bool {
        if user?.lowercased() == "git" { return true }
        for candidate in [hostName, alias].compactMap({ $0?.lowercased() })
        where !candidate.isEmpty {
            if gitServiceHosts.contains(candidate) { return true }
            // git-codecommit.<region>.amazonaws.com
            if candidate.hasPrefix("git-codecommit."),
               candidate.hasSuffix(".amazonaws.com") { return true }
        }
        return false
    }

    /// Environment words worth anchoring on. Only these produce an `env` tag: a
    /// guess here is worse than a blank, because a host labelled prod that is not
    /// prod is the one that gets connected to in a hurry.
    public static let environmentWords: Set<String> = [
        "prod", "production", "prd", "live",
        "stage", "staging", "stg", "preprod", "pre-prod",
        "qa", "uat", "test", "testing", "dev", "development", "devel",
        "sandbox", "sbx", "demo", "perf", "load", "int", "integration",
    ]

    // MARK: - Entry point

    public static func load(
        path: String = SSHConfigWriter.userConfigPath,
        excluding excluded: String = HangarConfig.sshIncludePath
    ) -> Result {
        var skipped: [String] = []
        var visited = Set<String>()
        let blocks = parseFile(path: path, excluding: expand(excluded),
                               depth: 0, visited: &visited, skipped: &skipped)
        let hosts = instances(from: blocks, skipped: &skipped)
        Log.info(.fleet, "ssh config imported",
                 ["hosts": "\(hosts.count)", "skipped": "\(skipped.count)"])
        return Result(hosts: hosts, skipped: skipped)
    }

    // MARK: - Parsing

    /// One `Host` block, reduced to the keywords that name a machine.
    public struct Block: Sendable, Equatable {
        public var names: [String]
        public var hostName: String?
        public var user: String?
        public var port: String?

        public init(names: [String], hostName: String? = nil,
                    user: String? = nil, port: String? = nil) {
            self.names = names
            self.hostName = hostName
            self.user = user
            self.port = port
        }
    }

    static func parseFile(path: String, excluding excluded: String, depth: Int,
                          visited: inout Set<String>,
                          skipped: inout [String]) -> [Block] {
        let full = expand(path)
        guard depth < maxIncludeDepth else {
            skipped.append("Include nesting past \(maxIncludeDepth) levels at \(path)")
            return []
        }
        guard full != excluded else { return [] }
        guard visited.insert(full).inserted else { return [] }
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return [] }
        return parse(text, relativeTo: (full as NSString).deletingLastPathComponent,
                     excluding: excluded, depth: depth,
                     visited: &visited, skipped: &skipped)
    }

    static func parse(_ text: String, relativeTo directory: String,
                      excluding excluded: String, depth: Int,
                      visited: inout Set<String>,
                      skipped: inout [String]) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        // A Match block cannot be evaluated without knowing the user, the host
        // and the result of any exec, so it is skipped whole. Guessing would
        // produce an alias that resolves to something other than what it says.
        var inMatch = false

        func flush() {
            if let block = current, !block.names.isEmpty { blocks.append(block) }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            guard let (keyword, value) = keywordAndValue(rawLine) else { continue }
            switch keyword {
            case "host":
                flush()
                inMatch = false
                current = Block(names: tokens(value))
            case "match":
                flush()
                inMatch = true
                skipped.append("Match block skipped: \(value)")
            case "include":
                // Followed inline, the way ssh reads it. A relative path is
                // relative to the directory of the file that named it.
                for pattern in tokens(value) {
                    for file in resolveInclude(pattern, relativeTo: directory) {
                        blocks += parseFile(path: file, excluding: excluded,
                                            depth: depth + 1, visited: &visited,
                                            skipped: &skipped)
                    }
                }
            case "hostname" where !inMatch:
                if current?.hostName == nil { current?.hostName = unquote(value) }
            case "user" where !inMatch:
                if current?.user == nil { current?.user = unquote(value) }
            case "port" where !inMatch:
                if current?.port == nil { current?.port = unquote(value) }
            default:
                break
            }
        }
        flush()
        return blocks
    }

    /// `Keyword value`, `Keyword=value`, and `  Keyword   value  ` all mean the
    /// same thing to ssh. Keywords are matched case-insensitively.
    static func keywordAndValue(_ line: String) -> (String, String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if let hash = trimmed.firstIndex(of: "#") { trimmed = String(trimmed[..<hash]) }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: " \t=")
        guard let split = trimmed.rangeOfCharacter(from: separators) else { return nil }
        let keyword = String(trimmed[..<split.lowerBound]).lowercased()
        let value = String(trimmed[split.lowerBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        guard !keyword.isEmpty, !value.isEmpty else { return nil }
        return (keyword, value)
    }

    static func tokens(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { unquote(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func unquote(_ value: String) -> String {
        var out = value.trimmingCharacters(in: .whitespaces)
        if out.count >= 2, out.hasPrefix("\""), out.hasSuffix("\"") {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }

    /// An `Include` may be a glob. Only the last path component is expanded,
    /// which is what people actually write (`config.d/*`).
    static func resolveInclude(_ pattern: String, relativeTo directory: String) -> [String] {
        var path = pattern
        if !path.hasPrefix("/") && !path.hasPrefix("~") {
            path = (directory as NSString).appendingPathComponent(path)
        }
        let full = expand(path)
        guard full.contains("*") || full.contains("?") else { return [full] }
        let parent = (full as NSString).deletingLastPathComponent
        let glob = (full as NSString).lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        return contents
            .filter { HangarConfig.wildcard(glob, $0) }
            .sorted()
            .map { (parent as NSString).appendingPathComponent($0) }
    }

    // MARK: - Blocks to hosts

    static func instances(from blocks: [Block], skipped: inout [String]) -> [Instance] {
        var hosts: [Instance] = []
        for block in blocks {
            // A pattern is not a host. `Host *` in the user's own file is a
            // defaults block, and importing it as a machine would put a host in
            // the menu that matches everything and connects to nothing.
            let usable = block.names.filter { name in
                !name.contains("*") && !name.contains("?") && !name.hasPrefix("!")
                    && SSHConfigValue.isSafeAlias(name)
            }
            guard let alias = usable.first else {
                if let first = block.names.first {
                    skipped.append("\(first): a pattern, not a host")
                }
                continue
            }
            // No HostName means ssh connects to the alias itself, which only
            // works when the alias is a real name.
            let target = block.hostName ?? alias
            guard SSHConfigValue.isEmittable(target) else {
                skipped.append("\(alias): hostname cannot be used")
                continue
            }
            // Reported, never silently dropped: someone who really does keep a
            // shell host behind `User git` has to be able to see why it is
            // missing rather than conclude Hangar cannot read their file.
            if isGitService(alias: alias, hostName: block.hostName, user: block.user) {
                skipped.append("\(alias): a git remote, not a host you can ssh into")
                continue
            }
            var tags: [String: String] = ["Name": alias, "hostname": target]
            if let user = block.user, !user.isEmpty { tags["ssh_config_user"] = user }
            if let port = block.port, !port.isEmpty { tags["ssh_config_port"] = port }
            // Every other name on the Host line stays searchable: people write
            // `Host db1 database1 db-primary` precisely so any of them works.
            if usable.count > 1 {
                tags["aliases"] = usable.dropFirst().joined(separator: " ")
            }
            hosts.append(Instance(
                id: "ssh:\(alias)", state: "unknown", type: "", privateIP: nil,
                publicIP: nil, availabilityZone: nil, launchTime: "",
                tags: tags, source: .sshConfig, preferredAlias: alias))
        }
        return derive(tags: hosts)
    }

    // MARK: - Tags from names

    /// Reads product, env and role out of the names people already use.
    ///
    /// Done over the whole set rather than one host at a time, because a leading
    /// component is only a grouping if more than one host shares it. `payments`
    /// in front of four hosts is a product; a component that appears once is just
    /// part of that machine's name, and promoting it would fill the menu with
    /// groups of one.
    public static func derive(tags hosts: [Instance]) -> [Instance] {
        var leadCounts: [String: Int] = [:]
        for host in hosts {
            if let lead = leadComponent(host.aliasStem) {
                leadCounts[lead, default: 0] += 1
            }
        }
        return hosts.map { host in
            var updated = host
            let parts = split(host.aliasStem)
            if let env = parts.first(where: { environmentWords.contains($0.lowercased()) }) {
                updated.tags["env"] = env.lowercased()
            }
            if let lead = leadComponent(host.aliasStem), (leadCounts[lead] ?? 0) > 1,
               !environmentWords.contains(lead.lowercased()) {
                updated.tags["product"] = lead
            }
            updated.tags["Name"] = role(for: host.aliasStem,
                                        product: updated.tags["product"],
                                        env: updated.tags["env"])
            return updated
        }
    }

    /// For a dotted name the product-ish label is the registrable part of the
    /// domain (`example` in `web1.prod.example.com`); for a flat name it is the
    /// first component.
    static func leadComponent(_ alias: String) -> String? {
        let labels = alias.split(separator: ".").map(String.init)
        if labels.count >= 3 {
            return labels[labels.count - 2]
        }
        let parts = split(alias)
        guard parts.count > 1, let first = parts.first, !first.isEmpty else { return nil }
        return first
    }

    /// What is left of the name once the parts that became groups are taken out.
    /// Never empty: a host with nothing left keeps its whole alias, because a
    /// blank row in the menu is worse than a repeated one.
    static func role(for alias: String, product: String?, env: String?) -> String {
        let firstLabel = alias.split(separator: ".").first.map(String.init) ?? alias
        if firstLabel != alias { return firstLabel }
        var parts = split(alias)
        if let product, let index = parts.firstIndex(of: product) { parts.remove(at: index) }
        if let env, let index = parts.firstIndex(where: { $0.lowercased() == env }) {
            parts.remove(at: index)
        }
        let remaining = parts.joined(separator: "-")
        return remaining.isEmpty ? alias : remaining
    }

    static func split(_ alias: String) -> [String] {
        alias.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
