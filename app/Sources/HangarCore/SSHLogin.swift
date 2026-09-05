import Foundation

public enum SSHLogin {
    /// Logins worth trying when a configured one fails: whatever ssh already
    /// resolves, the local account, then the standard cloud-image defaults.
    public static func candidates(effective: String?) -> [String] {
        var candidates: [String] = []
        if let effective, !effective.isEmpty { candidates.append(effective) }
        candidates.append(NSUserName())
        candidates += ["ec2-user", "rocky", "ubuntu", "admin", "centos",
                       "debian", "fedora", "almalinux", "cloud-user", "opc"]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The conventional login for an AMI, from what `DescribeInstances` already
    /// said about it.
    ///
    /// `platformDetails` is a billing field, so it separates Red Hat, SUSE and
    /// Ubuntu Pro but lumps Amazon Linux and stock Ubuntu together under
    /// "Linux/UNIX". A weak hint, but a free one, and putting it first is often
    /// the difference between one authentication attempt and six.
    public static func expected(forPlatform platform: String?) -> String? {
        guard let platform, !platform.isEmpty else { return nil }
        let lowered = platform.lowercased()
        if lowered.contains("ubuntu")   { return "ubuntu" }
        if lowered.contains("red hat") || lowered.contains("rhel") { return "ec2-user" }
        if lowered.contains("suse")     { return "ec2-user" }
        if lowered.contains("debian")   { return "admin" }
        if lowered.contains("windows")  { return nil }
        return nil
    }

    /// How many logins one probe may try before giving up.
    ///
    /// The full candidate list is twelve, and twelve failed authentications
    /// against one host is what trips fail2ban. Six is enough for the platform
    /// hint plus the common cloud images, and it is bounded.
    public static let probeLimit = 6

    /// The order to try, for a host Hangar is learning the login for. The
    /// platform's own convention goes first, then whatever ssh already resolves,
    /// then the usual suspects.
    public static func probeOrder(platform: String?, effective: String?) -> [String] {
        var ordered: [String] = []
        if let guess = expected(forPlatform: platform) { ordered.append(guess) }
        ordered += candidates(effective: effective)
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert($0).inserted }.prefix(probeLimit))
    }

    /// How many hosts a probe may ask. More than one because the first may be
    /// unreachable, few enough that an unreachable fleet costs almost nothing.
    public static let probeHostLimit = 3

    /// Hosts worth asking, best first.
    ///
    /// A host already in `known_hosts` has been connected to from this machine
    /// before, which is the only evidence available that it is reachable at all.
    /// Preferring those matters more than it sounds: on a fleet behind a VPN or a
    /// bastion, most hosts are not reachable right now, and picking merely the
    /// first *running* one wastes the probe on a host that cannot answer.
    public static func probeCandidates(from instances: [Instance],
                                       preferring known: Set<String> = [],
                                       limit: Int = probeHostLimit) -> [Instance] {
        let usable = instances.filter {
            $0.state == "running"
                && !($0.platform ?? "").lowercased().contains("windows")
                && $0.host != nil
                && $0.isWrittenToSSHConfig
        }
        let proven = usable.filter { known.contains(($0.host ?? "").lowercased()) }
        let rest = usable.filter { !known.contains(($0.host ?? "").lowercased()) }
        return Array((proven + rest).prefix(limit))
    }

    /// Hostnames this machine has an ssh host key for.
    ///
    /// Hashed entries are skipped rather than guessed at: `HashKnownHosts` stores
    /// an HMAC, and matching one requires the salt per line, which is more work
    /// than this hint is worth.
    public static func knownHostnames(paths: [String]) -> Set<String> {
        var names = Set<String>()
        for path in paths {
            let expanded = NSString(string: path).expandingTildeInPath
            guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                continue
            }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      !trimmed.hasPrefix("|") else { continue }
                guard let field = trimmed.split(separator: " ").first else { continue }
                for var name in field.split(separator: ",").map(String.init) {
                    // `[host]:2222` is how a non-default port is recorded.
                    if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
                        name = String(name[name.index(after: name.startIndex)..<close])
                    }
                    if !name.isEmpty { names.insert(name.lowercased()) }
                }
            }
        }
        return names
    }

    /// Whether ssh never got far enough to have an opinion about the login.
    ///
    /// The distinction decides whether the probe has had its answer. "Permission
    /// denied" is an answer: the host is there and that login is wrong. A refused
    /// connection is not, and burning the one probe on it means the login is never
    /// learned, even once the user is back on the VPN.
    public static func isUnreachable(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        for phrase in ["connection refused", "connection timed out", "operation timed out",
                       "no route to host", "could not resolve", "name or service not known",
                       "network is unreachable", "host is down", "no address associated",
                       "connection closed by remote host", "broken pipe",
                       "kex_exchange_identification", "connection reset"] where lowered.contains(phrase) {
            return true
        }
        // ssh could not even be told where to go.
        return lowered.contains("hostname") && lowered.contains("nodename")
    }
}

/// What the login probe has done so far, so it neither repeats forever nor gives
/// up after one attempt that never reached anything.
public struct LoginProbeState: Codable, Sendable, Equatable {
    /// Launches on which the probe has run.
    public var attempts: Int
    /// True once a host actually answered, whatever it said.
    public var settled: Bool

    public init(attempts: Int = 0, settled: Bool = false) {
        self.attempts = attempts
        self.settled = settled
    }

    /// Give up after this many launches without ever reaching a host.
    public static let maxAttempts = 5

    public var shouldRun: Bool { !settled && attempts < LoginProbeState.maxAttempts }

    public static func load(from path: String = HangarConfig.loginProbedMarkerPath)
        -> LoginProbeState {
        guard let data = FileManager.default.contents(atPath: path) else {
            return LoginProbeState()
        }
        // An empty marker is one written by an earlier version, which meant
        // "done". Honour it rather than probing someone who already settled.
        guard !data.isEmpty,
              let state = try? JSONDecoder().decode(LoginProbeState.self, from: data) else {
            return LoginProbeState(attempts: 0, settled: true)
        }
        return state
    }

    public func save(to path: String = HangarConfig.loginProbedMarkerPath) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        PrivateFile.write(data, to: path)
    }
}

/// What `ssh` gets for a host. Kept out of the UI layer so it can be tested: for
/// an unmanaged host the target is a hostname tag rather than one of our own
/// slugified aliases.
///
/// One question, one answer. The panel types a line into a live terminal and the
/// `hangar` command replaces itself with the process, and those must not be two
/// different opinions about which user or key a host gets. `vector` decides;
/// both other forms render it.
public enum SSHCommand {

    /// One element of the vector, and whether it came from outside.
    ///
    /// The distinction is not decoration: a line typed into a shell has to quote
    /// everything a tag or a config file supplied, and quoting the flags we wrote
    /// ourselves would make it unreadable.
    public enum Argument: Equatable, Sendable {
        /// Written in this file.
        case literal(String)
        /// A tag, a hand-edited config value, or a user's own path.
        case value(String)

        public var text: String {
            switch self {
            case .literal(let text), .value(let text): return text
            }
        }

        var shell: String {
            switch self {
            case .literal(let text): return text
            case .value(let text):   return Shell.quoted(text)
            }
        }
    }

    /// The decision, once.
    ///
    /// `--` before the target for the reason `SSHProbe` carries it: a hostname
    /// tag of `-oProxyCommand=…` is read as an option wherever it reaches an
    /// argument vector, and `ProxyCommand` is something ssh executes. Quoting
    /// stops a shell reading it. Only `--` stops ssh reading it.
    public static func vector(target: String, user: String?, identityFile: String?,
                              managedByConfig: Bool) -> [Argument] {
        // A host Hangar wrote into ssh_config needs no flags at all; ssh already
        // knows the user and key. Only unmanaged hosts get them spelled out.
        guard !managedByConfig else { return [.literal("--"), .value(target)] }
        var parts: [Argument] = []
        if let identityFile, !identityFile.isEmpty {
            parts += [.literal("-i"), .value(identityFile)]
        }
        parts.append(.literal("--"))
        if let user, !user.isEmpty {
            parts.append(.value("\(user)@\(target)"))
        } else {
            parts.append(.value(target))
        }
        return parts
    }

    /// The vector as `ssh` receives it, argv[0] included, for a caller that
    /// starts the process rather than typing it.
    public static func arguments(target: String, user: String?,
                                 identityFile: String?,
                                 managedByConfig: Bool) -> [String] {
        ["ssh"] + vector(target: target, user: user, identityFile: identityFile,
                         managedByConfig: managedByConfig).map(\.text)
    }

    /// The `ssh …` line to type into a live terminal session.
    public static func line(target: String, user: String?, identityFile: String?,
                            managedByConfig: Bool) -> String {
        (["ssh"] + vector(target: target, user: user, identityFile: identityFile,
                          managedByConfig: managedByConfig).map(\.shell))
            .joined(separator: " ")
    }
}

/// What a typed answer to "which of these?" means.
///
/// Here rather than beside the reader so the rules are testable: the process
/// supplies a string and gets back an index or nothing, and nothing always means
/// connect to no one.
public enum Chooser {
    public static func choice(_ input: String?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        // EOF, an empty line, or anything that is not one of the numbers offered.
        // Cancelling has to be the easy answer: this is about to open a session
        // on somebody's production host.
        guard let text = input?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let number = Int(text), number >= 1, number <= count else { return nil }
        return number - 1
    }
}
