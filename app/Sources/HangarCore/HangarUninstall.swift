import Foundation

/// Removing Hangar completely.
///
/// A reset leaves the app installed and leaves the user's `~/.ssh/config` alone,
/// because after a reset Hangar is still there to use. An uninstall is the case
/// where neither is right: the whole `~/.hangar` directory goes rather than the
/// files in it, and the Include line Hangar added is taken back out so nothing
/// is left pointing at a file that no longer exists. AWS credentials and the
/// rest of `~/.ssh/config` are still not Hangar's to delete.
public enum HangarUninstall {
    public struct Outcome: Sendable, Equatable {
        /// Paths that existed and were removed.
        public var removed: [String]
        /// Paths that could not be removed, with the reason.
        public var failed: [String]
        /// Whether the Include line was found in ~/.ssh/config and taken out.
        public var includeLineRemoved: Bool

        public init(removed: [String], failed: [String], includeLineRemoved: Bool) {
            self.removed = removed
            self.failed = failed
            self.includeLineRemoved = includeLineRemoved
        }
    }

    /// What an uninstall removes, whether or not it currently exists. The
    /// directory rather than its contents: an empty ~/.hangar left behind is
    /// what made a reinstall look like the delete had not taken.
    public static var paths: [String] {
        [HangarConfig.home, HangarConfig.sshIncludePath]
    }

    public static func perform(
        sshConfigPath: String = NSString(string: "~/.ssh/config").expandingTildeInPath
    ) -> Outcome {
        Log.info(.uninstall, "removing Hangar's files")
        let fm = FileManager.default
        var removed: [String] = []
        var failed: [String] = []
        for path in paths where fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                removed.append(path)
            } catch {
                failed.append("\(path): \(error.localizedDescription)")
            }
        }

        var includeLineRemoved = false
        do {
            includeLineRemoved = try SSHConfigWriter.removeIncludeLine(from: sshConfigPath)
        } catch {
            failed.append("\(sshConfigPath): \(error.localizedDescription)")
        }
        Log.info(.uninstall, "files removed",
                 ["removed": "\(removed.count)", "failed": "\(failed.count)",
                  "include_line": includeLineRemoved ? "removed" : "absent"])
        return Outcome(removed: removed, failed: failed,
                       includeLineRemoved: includeLineRemoved)
    }

    /// One paragraph for the confirmation dialog, listing exactly what goes.
    public static var description: String {
        "Removes ~/.hangar, the ssh aliases Hangar generated, and the Include "
            + "line Hangar added to ~/.ssh/config. Hangar stops opening at login, "
            + "then quits and moves every installed copy to the Trash, where you "
            + "can put them back. Your AWS credentials and the rest of your "
            + "~/.ssh/config are not touched."
    }
}
