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

    /// Whether a fleet is worth probing at all. A Windows-only fleet has no ssh
    /// login to learn, and a fleet with nothing running has nothing to ask.
    public static func probeCandidate(from instances: [Instance]) -> Instance? {
        instances.first {
            $0.state == "running"
                && !($0.platform ?? "").lowercased().contains("windows")
                && $0.host != nil
                && $0.isWrittenToSSHConfig
        }
    }
}

/// The `ssh …` line Hangar hands to a terminal. Kept out of the UI layer so it
/// can be tested: it is typed into a live shell, and for an unmanaged host the
/// target is a hostname tag rather than one of our own slugified aliases.
public enum SSHCommand {
    public static func line(target: String, user: String?, identityFile: String?,
                            managedByConfig: Bool) -> String {
        // A host Hangar wrote into ssh_config needs no flags at all; ssh already
        // knows the user and key. Only unmanaged hosts get them spelled out.
        guard !managedByConfig else { return "ssh \(Shell.quoted(target))" }
        var parts = ["ssh"]
        if let identityFile, !identityFile.isEmpty {
            parts.append("-i \(Shell.quoted(identityFile))")
        }
        if let user, !user.isEmpty {
            parts.append(Shell.quoted("\(user)@\(target)"))
        } else {
            parts.append(Shell.quoted(target))
        }
        return parts.joined(separator: " ")
    }
}
