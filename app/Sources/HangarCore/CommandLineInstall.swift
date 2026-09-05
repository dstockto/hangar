import Foundation

/// Where the `hangar` command goes so the shell can find it.
///
/// The decision is pure and lives here; the app layer does the probing and the
/// linking. /usr/local/bin is the line every README reaches for and it is
/// root-owned on a stock Mac, so the first install attempt is a sudo prompt for
/// something that did not need one. A directory the user already owns, already
/// on their PATH, needs no privilege at all.
public enum CommandLineInstall {
    public static let commandName = "hangar"

    /// Best first. `~/.local/bin` and `~/bin` are the user's own; the Homebrew
    /// prefix is theirs on a Homebrew machine; /usr/local/bin is last because it
    /// is the one that usually needs sudo.
    public static let preferred = [
        NSString(string: "~/.local/bin").expandingTildeInPath,
        "/opt/homebrew/bin",
        NSString(string: "~/bin").expandingTildeInPath,
        "/usr/local/bin",
    ]

    /// The directory to link into: the first preferred one that is both on PATH
    /// and writable. Nil when the shell would not find it or the user could not
    /// write it, which is a real answer rather than a failure to guess.
    public static func destination(onPath: [String], writable: Set<String>) -> String? {
        let path = Set(onPath.map(normalized))
        return preferred.first { path.contains(normalized($0)) && writable.contains($0) }
    }

    /// PATH split into directories, empty entries dropped.
    public static func searchPath(
        _ raw: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String] {
        (raw ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// The line to run by hand when nothing on PATH can be written. Quoted,
    /// because an app can live under a path with a space in it.
    public static func manualCommand(tool: String,
                                     directory: String = "/usr/local/bin") -> String {
        "sudo ln -sfn \(Shell.quoted(tool)) "
            + "\(Shell.quoted((directory as NSString).appendingPathComponent(commandName)))"
    }

    /// A trailing slash or a doubled separator should not make two names for one
    /// directory, or PATH matching misses a directory that is plainly there.
    static func normalized(_ directory: String) -> String {
        let standardized = (directory as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast()) : standardized
    }

    /// What the shell would find, and whether it is ours.
    ///
    /// A `hangar` that is not our symlink is left alone and reported. It is far
    /// more likely to be something the user put there deliberately than a stale
    /// copy of ours, and overwriting it would be Hangar outranking its user
    /// again.
    public enum State: Sendable, Equatable {
        /// Installed, and pointing at this copy of the app.
        case installed(link: String)
        /// A link of ours pointing at a bundle that is no longer there.
        case broken(link: String)
        /// Something else owns the name.
        case claimed(link: String)
        /// Not installed, with the directory it would go in, or nil when nowhere
        /// on PATH can be written.
        case absent(destination: String?)

        public var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }
}
