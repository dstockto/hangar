import Foundation

/// Clearing Hangar's state.
///
/// Everything Hangar knows lives in files it owns, which is what makes a reset
/// possible at all: there is no preferences database and no server, so removing
/// the files is the whole operation. Two scopes, because they answer different
/// questions. "The fleet looks wrong" wants the cache gone. "I want to start
/// over" wants the settings gone too.
public enum HangarReset {
    public enum Scope: Sendable, Equatable {
        /// The cached fleet and the update timestamp. Settings are kept.
        case cache
        /// Everything: cache, settings, the onboarding marker, and the ssh file
        /// Hangar generates. The user's own ~/.ssh/config is never touched.
        case everything
    }

    public struct Outcome: Sendable, Equatable {
        /// Paths that existed and were removed.
        public var removed: [String]
        /// Paths that could not be removed, with the reason.
        public var failed: [String]

        public var isEmpty: Bool { removed.isEmpty && failed.isEmpty }
    }

    /// Paths a scope covers, whether or not they currently exist.
    public static func paths(for scope: Scope) -> [String] {
        let cache = [
            HangarConfig.cachePath,
            UpdateSchedule.stampPath,
        ]
        switch scope {
        case .cache:
            return cache
        case .everything:
            return cache + [
                HangarConfig.path,
                HangarConfig.onboardedMarkerPath,
                // Hangar's own generated file. The Include line in the user's
                // ~/.ssh/config stays: that file is theirs, and the line is
                // harmless pointing at nothing.
                HangarConfig.sshIncludePath,
            ]
        }
    }

    @discardableResult
    public static func perform(_ scope: Scope) -> Outcome {
        let fm = FileManager.default
        var removed: [String] = []
        var failed: [String] = []
        for path in paths(for: scope) where fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                removed.append(path)
            } catch {
                failed.append("\(path): \(error.localizedDescription)")
            }
        }
        return Outcome(removed: removed, failed: failed)
    }

    /// One sentence for a confirmation dialog, listing exactly what goes.
    public static func description(of scope: Scope) -> String {
        switch scope {
        case .cache:
            return "Forgets the cached fleet and when Hangar last checked for "
                + "updates. Your settings, tag mapping and menu levels are kept, "
                + "and the fleet is fetched again straight away."
        case .everything:
            return "Forgets the cached fleet, your settings, the tag mapping, the "
                + "menu levels, and the ssh aliases Hangar generated. Hangar "
                + "starts as it does on a fresh install. Your own ~/.ssh/config "
                + "and your AWS credentials are not touched."
        }
    }
}
