import Foundation

/// The argument vector for a non-interactive auth check.
///
/// Kept out of the UI layer so it can be tested, because this is the one place a
/// hostname tag reaches `ssh` with a trailing argument after it. That detail is
/// the whole reason `--` is here: with a remote command following the host, `ssh`
/// parses a host beginning with `-o` as an option, and `-oProxyCommand=…` runs
/// under `/bin/sh`. An argument vector does not prevent that. `--` does.
public enum SSHProbe {
    public static func arguments(host: String, user: String?,
                                 identityFile: String?) -> [String] {
        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                         "-o", "StrictHostKeyChecking=accept-new"]
        if let identityFile, !identityFile.isEmpty {
            arguments += ["-o", "IdentitiesOnly=yes",
                          "-i", (identityFile as NSString).expandingTildeInPath]
        }
        if let user, !user.isEmpty { arguments += ["-l", user] }
        // Everything after this is a host and a remote command, never an option.
        arguments += ["--", host, "true"]
        return arguments
    }

    /// The vector for asking ssh what it would use for a host, which takes no
    /// trailing argument but is separated for the same reason.
    public static func effectiveSettingsArguments(target: String) -> [String] {
        ["-G", "--", target]
    }
}
