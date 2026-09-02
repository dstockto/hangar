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
