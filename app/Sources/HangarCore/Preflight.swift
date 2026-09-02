import Foundation

/// Reads the local setup and reports what works and what does not.
///
/// Everything Hangar needs lives in the user's home directory, so all of this is
/// checkable before the user hits a failure. UI-free on purpose: the same checks
/// back the first-run screen and the menubar's setup item, and they are testable.
public struct Preflight: Sendable {
    public enum Level: Sendable { case ok, warning, problem }

    public struct Check: Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String
        public var level: Level
        /// A machine-readable name for the remedy the UI should offer, if any.
        public var remedy: Remedy?

        public init(id: String, title: String, detail: String,
                    level: Level, remedy: Remedy? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.level = level
            self.remedy = remedy
        }
    }

    public enum Remedy: Sendable, Hashable {
        case addIncludeLine
        case copyLoginCommand(String)
        case openConfig
    }

    public var checks: [Check]

    public init(checks: [Check]) { self.checks = checks }

    public var worst: Level {
        if checks.contains(where: { $0.level == .problem }) { return .problem }
        if checks.contains(where: { $0.level == .warning }) { return .warning }
        return .ok
    }

    public var isUsable: Bool { worst != .problem }

    // MARK: - Individual checks, each independently testable

    /// AWS profiles found across ~/.aws/config and ~/.aws/credentials.
    public static func profilesCheck(_ files: AWSConfigFiles) -> Check {
        let names = files.profileNames
        if names.isEmpty {
            return Check(
                id: "profiles", title: "AWS profiles",
                detail: "No profiles found in ~/.aws/config or ~/.aws/credentials.",
                level: .problem)
        }
        let listed = names.prefix(4).joined(separator: ", ")
        let suffix = names.count > 4 ? ", and \(names.count - 4) more" : ""
        return Check(
            id: "profiles",
            title: names.count == 1 ? "1 AWS profile found" : "\(names.count) AWS profiles found",
            detail: listed + suffix, level: .ok)
    }

    /// Whether the ssh aliases Hangar writes can actually be resolved by ssh.
    public static func sshIncludeCheck(
        includePresent: Bool, fileExists: Bool, hostCount: Int
    ) -> Check {
        if includePresent {
            return Check(
                id: "ssh-include", title: "SSH aliases active",
                detail: fileExists
                    ? "~/.ssh/config includes \(hostCount) Hangar aliases."
                    : "~/.ssh/config has the Include line; aliases appear after the first sync.",
                level: .ok)
        }
        return Check(
            id: "ssh-include", title: "SSH aliases not active yet",
            detail: "Add Include ~/.ssh/config.d/hangar to ~/.ssh/config so aliases "
                + "work in ssh, scp, rsync, and Ansible. Hangar connects either way.",
            level: .warning, remedy: .addIncludeLine)
    }

    /// Hangar groups and names hosts from tags, so untagged fleets look broken.
    public static func taggingCheck(instances: [Instance]) -> Check {
        guard !instances.isEmpty else {
            return Check(
                id: "tags", title: "No hosts discovered",
                detail: "No running or stopped instances were found in this region.",
                level: .warning)
        }
        let untagged = instances.filter(TagMapping.isUngrouped)
        if untagged.isEmpty {
            let products = Set(instances.map(\.product)).filter { !$0.isEmpty }.count
            let environments = Set(instances.map(\.env)).filter { !$0.isEmpty }.count
            return Check(
                id: "tags", title: "\(instances.count) hosts indexed",
                detail: "\(products) products, \(environments) environments.", level: .ok)
        }
        if untagged.count == instances.count {
            return Check(
                id: "tags", title: "Hangar cannot read this fleet's tags",
                detail: "All \(instances.count) instances came back with no tag Hangar "
                    + "recognises, so they group under untagged and are named by "
                    + "instance id. Map your own tag keys under \"tags\" in "
                    + "~/.hangar/config.json, or tag hosts with Name.",
                level: .warning, remedy: .openConfig)
        }
        return Check(
            id: "tags", title: "\(instances.count) hosts indexed",
            detail: "\(untagged.count) carry no tag Hangar recognises and group under "
                + "untagged. Map your tag keys under \"tags\" in "
                + "~/.hangar/config.json if they use different names.",
            level: .warning, remedy: .openConfig)
    }

    /// The terminal Hangar will hand sessions to.
    public static func terminalCheck(configured: String?, installed: Bool,
                                     fallbackInstalled: Bool) -> Check {
        let name = (configured ?? "iterm").lowercased().contains("terminal")
            ? "Terminal" : "iTerm2"
        if installed {
            return Check(id: "terminal", title: "\(name) found",
                         detail: "Sessions open in \(name).", level: .ok)
        }
        if fallbackInstalled {
            return Check(
                id: "terminal", title: "\(name) not installed",
                detail: "Sessions will open in Terminal instead. Change this in "
                    + "~/.hangar/config.json.",
                level: .warning, remedy: .openConfig)
        }
        return Check(id: "terminal", title: "No terminal found",
                     detail: "Neither iTerm2 nor Terminal could be located.",
                     level: .problem)
    }

    public static func hotkeyCheck(problem: String?, combination: String) -> Check {
        if let problem {
            return Check(id: "hotkey", title: "Shortcut unavailable",
                         detail: problem, level: .warning, remedy: .openConfig)
        }
        return Check(id: "hotkey", title: "Shortcut ready",
                     detail: "Press \(combination) from any app.", level: .ok)
    }

    /// Credentials, with a recovery only when one actually applies. The advice is
    /// computed from the profile that was tried, so a static-keys user is never
    /// told to run an SSO command they have no use for.
    public static func credentialsCheck(sourceLabel: String?,
                                        advice: CredentialAdvice.Advice?) -> Check {
        if let advice {
            return Check(
                id: "credentials",
                title: advice.command != nil ? "Credentials expired"
                                             : "Credentials unavailable",
                detail: advice.message, level: .problem,
                remedy: advice.command.map { Remedy.copyLoginCommand($0) })
        }
        return Check(id: "credentials", title: "Credentials resolved",
                     detail: sourceLabel ?? "Ready.", level: .ok)
    }
}
