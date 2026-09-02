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
