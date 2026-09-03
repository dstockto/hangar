import Foundation

/// One public key an ssh agent is holding. The private half stays wherever it
/// lives; nothing here can read it and nothing here tries.
public struct AgentKey: Sendable, Equatable, Codable {
    public var algorithm: String
    public var blob: String
    /// The agent's own label. 1Password puts the vault item's title here, which
    /// is the only name a person will recognise.
    public var comment: String

    public init(algorithm: String, blob: String, comment: String) {
        self.algorithm = algorithm
        self.blob = blob
        self.comment = comment
    }

    /// Exactly the line `ssh-add -L` produced, which is also the file format
    /// `IdentityFile` expects when it points at a public key.
    public var publicKeyLine: String {
        comment.isEmpty ? "\(algorithm) \(blob)" : "\(algorithm) \(blob) \(comment)"
    }

    public var title: String {
        comment.isEmpty ? "\(algorithm) \(String(blob.suffix(8)))" : comment
    }

    /// Filename-safe, and unique enough to sit in a directory with its siblings.
    /// The blob suffix is always appended: two vault items can share a title,
    /// and the file it names is what `IdentityFile` points at.
    public var slug: String {
        let base = Instance.slug(comment)
        let tail = String(blob.suffix(8)).filter { $0.isLetter || $0.isNumber }
        return base.isEmpty ? "key-\(tail)" : "\(base)-\(tail)"
    }
}

/// An ssh agent Hangar found on the machine, and what it is holding.
public struct SSHAgent: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case onePassword, secretive, environment

        public var name: String {
            switch self {
            case .onePassword: return "1Password"
            case .secretive:   return "Secretive"
            case .environment: return "your ssh agent"
            }
        }
    }

    public var kind: Kind
    public var socket: String
    public var keys: [AgentKey]
    /// Set when the socket is there but produced no usable list. For 1Password
    /// that almost always means the app is locked.
    public var problem: String?

    public init(kind: Kind, socket: String, keys: [AgentKey], problem: String? = nil) {
        self.kind = kind
        self.socket = socket
        self.keys = keys
        self.problem = problem
    }

    public var name: String { kind.name }
    public var isUsable: Bool { !keys.isEmpty }
}

/// Where the ssh key for a host comes from.
///
/// The unit of configuration is the source, not a path, because for a vault
/// user, a hardware key user, or anyone on an agent the key is not a path. The
/// default stays `sshDefault`: say nothing and let ssh and the agent behave as
/// they already do.
public enum KeySource {

    // MARK: - Known agents

    /// The socket 1Password 8 publishes. Under Group Containers, so the path has
    /// a space in it, which is why every emitted value goes through quoting.
    public static let onePasswordSocket =
        "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    public static let secretiveSocket =
        "~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"

    /// How long the agent gets to answer. A locked vault is the shape that hangs,
    /// and the setup window is waiting on this.
    public static let listTimeout: TimeInterval = 5

    /// The sockets worth looking at, richest first: the two apps that publish one
    /// at a known path, then whatever the user's shell already points at.
    public static func knownSockets(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [(kind: SSHAgent.Kind, socket: String)] {
        var candidates: [(SSHAgent.Kind, String)] = [
            (.onePassword, expand(onePasswordSocket)),
            (.secretive, expand(secretiveSocket)),
        ]
        if let socket = environment["SSH_AUTH_SOCK"], !socket.isEmpty {
            candidates.append((.environment, socket))
        }
        return candidates.map { (kind: $0.0, socket: $0.1) }
    }

    /// Agents present on this machine, richest first. A socket that does not
    /// exist produces no entry, so a machine with none of this shows nothing
    /// rather than three empty rows.
    ///
    /// The candidate list is a parameter so this is testable on a machine that
    /// has a real agent running, which is every machine anyone develops on.
    public static func detectAgents(
        candidates: [(kind: SSHAgent.Kind, socket: String)]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        list: (String) -> (keys: [AgentKey], problem: String?) = KeySource.listKeys
    ) -> [SSHAgent] {
        var found: [SSHAgent] = []
        var seen = Set<String>()
        for (kind, socket) in candidates ?? knownSockets(environment: environment) {
            guard FileManager.default.fileExists(atPath: socket),
                  seen.insert(socket).inserted else { continue }
            let answer = list(socket)
            found.append(SSHAgent(
                kind: kind, socket: socket, keys: answer.keys,
                problem: answer.keys.isEmpty
                    ? (answer.problem ?? emptyAgentAdvice(for: kind)) : nil))
        }
        return found
    }

    /// What to do about an agent holding nothing, worded for the agent that is
    /// actually there. Telling someone on a forwarded agent to unlock an app they
    /// do not have is the mistake `CredentialAdvice` was written to stop.
    static func emptyAgentAdvice(for kind: SSHAgent.Kind) -> String {
        switch kind {
        case .onePassword:
            return "No keys available. Unlock 1Password and turn on its SSH agent, "
                + "then re-check."
        case .secretive:
            return "No keys available. Open Secretive and create or unlock a key, "
                + "then re-check."
        case .environment:
            return "The agent at SSH_AUTH_SOCK is holding no keys. "
                + "ssh-add a key, then re-check."
        }
    }

    /// Asks the agent what it holds. No `op`, no vendor CLI: an agent that ssh
    /// can use is an agent `ssh-add` can list, and the comment on each line is
    /// the name the user gave the key.
    public static func listKeys(socket: String) -> (keys: [AgentKey], problem: String?) {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socket
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/ssh-add", ["-L"], environment: environment, timeout: listTimeout)
            // ssh-add exits 1 with "The agent has no identities." A vault that is
            // simply locked looks identical from out here, so the advice for an
            // empty list is composed by the caller, which knows which agent it is.
            return (parseKeyList(result.out), nil)
        } catch {
            Log.warning(.ssh, "agent did not answer",
                        ["error": error.localizedDescription])
            return ([], error.localizedDescription)
        }
    }

    /// One key per line: `<algorithm> <base64> [comment]`. Split on the first two
    /// spaces only, so a comment such as "Prod SRE key" survives whole.
    public static func parseKeyList(_ text: String) -> [AgentKey] {
        var keys: [AgentKey] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let algorithm = parts[0]
            let blob = parts[1]
            guard isKeyAlgorithm(algorithm), isBase64(blob) else { continue }
            let comment = parts.count > 2
                ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            keys.append(AgentKey(algorithm: algorithm, blob: blob, comment: comment))
        }
        return keys
    }

    /// The families ssh actually offers. Checked rather than assumed because the
    /// value ends up in a file ssh parses.
    static func isKeyAlgorithm(_ value: String) -> Bool {
        guard value.count <= 64 else { return false }
        return value.hasPrefix("ssh-") || value.hasPrefix("ecdsa-")
            || value.hasPrefix("sk-") || value.hasPrefix("rsa-")
    }

    static func isBase64(_ value: String) -> Bool {
        guard value.count >= 16, value.count <= 8192 else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=")
        }
    }

    // MARK: - Key files

    /// The private key names ssh itself tries, in ssh's own order. Only their
    /// presence is checked; nothing reads a private key.
    public static let keyFileNames = [
        "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk", "id_ecdsa", "id_rsa",
    ]

    public static func detectKeyFiles(in directory: String = "~/.ssh") -> [String] {
        let base = expand(directory)
        return keyFileNames
            .filter { FileManager.default.fileExists(atPath: (base as NSString)
                        .appendingPathComponent($0)) }
            .map { "\(directory)/\($0)" }
    }

    // MARK: - Materializing a public key

    public static var keyDirectory: String {
        (HangarConfig.home as NSString).appendingPathComponent("keys")
    }

    /// Writes the agent's public key where `IdentityFile` can point at it, and
    /// returns the path in `~` form so the config file stays portable.
    ///
    /// Rewritten every time, so a key rotated in the vault is picked up without
    /// the user doing anything.
    @discardableResult
    public static func materialize(_ key: AgentKey) -> String? {
        let name = "\(key.slug).pub"
        let path = (keyDirectory as NSString).appendingPathComponent(name)
        guard PrivateFile.write(Data((key.publicKeyLine + "\n").utf8), to: path) else {
            Log.error(.ssh, "could not write public key", ["name": name])
            return nil
        }
        return "~/.hangar/keys/\(name)"
    }

    /// Public keys Hangar wrote that no longer match a key the agent holds. Left
    /// behind they would be an `IdentityFile` pointing at a key nobody has.
    public static func staleKeyFiles(keeping keys: [AgentKey]) -> [String] {
        let wanted = Set(keys.map { "\($0.slug).pub" })
        let contents = (try? FileManager.default
            .contentsOfDirectory(atPath: keyDirectory)) ?? []
        return contents
            .filter { $0.hasSuffix(".pub") && !wanted.contains($0) }
            .map { (keyDirectory as NSString).appendingPathComponent($0) }
    }

    // MARK: - Choosing

    /// The settings that pin one agent key, ready to merge into the config.
    /// `IdentityFile` names the *public* key on purpose: with `IdentitiesOnly`
    /// that is how ssh is told which of the agent's keys to offer, and without
    /// it a vault holding a dozen keys runs past MaxAuthTries and fails on a
    /// host that would otherwise work.
    public static func settings(agent: SSHAgent, key: AgentKey,
                                user: String?) -> HangarConfig.SSHSettings? {
        guard let path = materialize(key) else { return nil }
        return HangarConfig.SSHSettings(
            user: user, identityFile: path, identityAgent: agent.socket,
            identitiesOnly: true)
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
