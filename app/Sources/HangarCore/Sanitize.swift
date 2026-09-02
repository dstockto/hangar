import Foundation

/// Guards for values that leave Hangar as something another program parses:
/// an ssh_config file, a shell command line, or an AWS endpoint hostname.
///
/// Everything here exists because the values are not ours. Instance tags are
/// written by whoever can tag the account, and paths and logins come from a
/// hand-edited config file, so neither is trusted input just because it arrived
/// over a signed connection.

// MARK: - ssh_config

public enum SSHConfigValue {
    /// Characters that would end the current option and start a new one, or that
    /// ssh_config offers no way to escape inside a quoted argument.
    private static let forbidden = CharacterSet(charactersIn: "\n\r\0\"")

    /// False for anything that could inject a second directive. A tag carrying a
    /// newline would otherwise be able to add ProxyCommand, which ssh runs.
    public static func isEmittable(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: forbidden) == nil
    }

    /// Wraps a value in the double quotes ssh_config understands when it contains
    /// whitespace. Without this a legitimate tag such as `web 1` produces
    /// `HostName web 1`, which ssh rejects outright, taking every other alias in
    /// the file down with it.
    public static func quoted(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            ? value
            : "\"\(value)\""
    }

    /// A value safe to place after `#` on a comment line.
    public static func comment(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Whether a value may be used as a name on a `Host` line.
    ///
    /// Stricter than `isEmittable` on purpose, because the `Host` line is a
    /// *pattern* list, not a value. A hostname tag of `*` becomes a catch-all
    /// that ssh accepts, and since Hangar's Include sits above everything in
    /// `~/.ssh/config` and ssh_config is first-match-wins, that one tag would
    /// take over every host the user has. A wildcard DNS record in a tag does
    /// the same thing by accident.
    ///
    /// A leading hyphen is refused too: such a name is parsed by `ssh` as an
    /// option rather than a host wherever it reaches an argument vector.
    public static func isSafeAlias(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253, !value.hasPrefix("-") else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    /// Whether a value may be used as an ssh_config keyword. Keywords are bare
    /// tokens; a keyword containing a space would write two ssh tokens.
    public static func isSafeKeyword(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

// MARK: - Shell

public enum Shell {
    /// Single-quoted for /bin/sh, with the standard close-escape-reopen trick for
    /// an embedded quote. Used for anything typed into a live terminal session.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Nothing that is going to be typed into a shell may carry a newline: it
    /// would submit the line early and run whatever follows.
    public static func isSingleLine(_ value: String) -> Bool {
        value.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r\0")) == nil
    }
}

// MARK: - Private files

public enum PrivateFile {
    /// Creates the file at 0600 before anything is written to it.
    ///
    /// `Data.write(options: .atomic)` creates its temporary file at the process
    /// umask and only tightens it afterwards, which leaves a window on first
    /// creation. Creating the destination first closes it, and the subsequent
    /// write inherits the existing mode.
    @discardableResult
    public static func write(_ data: Data, to path: String) -> Bool {
        let fm = FileManager.default
        ensureDirectory((path as NSString).deletingLastPathComponent)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return false
        }
        // Belt and braces: a destination that already existed keeps its own mode,
        // which may be looser than we want.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    /// Creates a directory at 0700, and tightens one that already exists.
    /// `createDirectory(attributes:)` does not change an existing directory, so a
    /// hand-made `mkdir ~/.hangar` would otherwise stay at the umask.
    public static func ensureDirectory(_ path: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}

// MARK: - AWS regions

public enum AWSRegion {
    /// Region names are lowercase letters, digits and hyphens. Checking is not
    /// pedantry: the region is interpolated straight into an endpoint hostname,
    /// and a typo such as `us west 2` makes an unparseable URL.
    public static func isValid(_ region: String) -> Bool {
        guard !region.isEmpty, region.count <= 64 else { return false }
        return region.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// The https endpoint for a service in a region, or a readable error.
    public static func endpoint(service: String, region: String,
                                path: String = "/") throws -> URL {
        guard isValid(region) else {
            throw HangarError.noProfile(
                "'\(region)' is not a valid AWS region name. Fix the region in "
                + "~/.aws/config or ~/.hangar/config.json.")
        }
        guard let url = URL(string: "https://\(service).\(region).amazonaws.com\(path)") else {
            throw HangarError.noProfile("could not build an endpoint for region '\(region)'")
        }
        return url
    }
}

// MARK: - Networking

public enum HangarHTTP {
    /// Every AWS call goes through a session with no disk cache and no cookie
    /// store. `URLSession.shared` keeps a shared on-disk `URLCache`, and the SSO
    /// federation endpoint answers with live secret access keys.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
}
