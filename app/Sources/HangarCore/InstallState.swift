import Foundation

/// Whether this launch is a first run, an upgrade, or a reinstall.
///
/// Deleting an app on macOS leaves its support files behind, which is why
/// uninstallers exist. That is the correct platform behaviour and the wrong
/// behaviour for someone who dragged Hangar to the Trash and installed a DMG
/// expecting to start over: they got their old cache, their old settings, and no
/// setup screen, which looks like the delete did not work.
///
/// So Hangar records which bundle it last ran from. A bundle newer than the
/// record, at a version that did not increase, is a reinstall.
public enum InstallState {
    public enum Launch: Sendable, Equatable {
        /// Nothing on disk. A genuine first run.
        case first
        /// A higher version than last time. Settings are kept, silently.
        case upgraded(from: String)
        /// The same version from a newly installed bundle: the app was replaced
        /// without the version moving, which is what a delete and reinstall
        /// looks like.
        case reinstalled(version: String)
        /// Same bundle as last time.
        case unchanged
    }

    struct Record: Codable, Equatable {
        var version: String
        /// Seconds since 1970 of the bundle's creation date. A copied bundle
        /// gets a new one, which is what makes a reinstall detectable.
        var bundleCreated: TimeInterval
    }

    public static var path: String {
        (HangarConfig.home as NSString).appendingPathComponent(".install")
    }

    static func read(from path: String = path) -> Record? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func write(_ record: Record, to path: String = path) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        PrivateFile.write(data, to: path)
    }

    /// The creation date of a bundle, which `ditto` and the Finder both reset
    /// when the bundle is copied into place.
    public static func bundleCreated(at url: URL) -> TimeInterval? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate?.timeIntervalSince1970
    }

    /// Classifies the launch and records the current bundle, so the answer is
    /// only ever given once per install.
    public static func classify(version: String, bundleCreated created: TimeInterval?,
                                statePath: String = path) -> Launch {
        let current = Record(version: version, bundleCreated: created ?? 0)
        defer { write(current, to: statePath) }

        guard let previous = read(from: statePath) else { return .first }
        if VersionCompare.isNewer(version, than: previous.version) {
            return .upgraded(from: previous.version)
        }
        // A tolerance, because a filesystem copy can round the timestamp.
        if let created, created > previous.bundleCreated + 1 {
            return .reinstalled(version: version)
        }
        return .unchanged
    }

    /// Whether this launch should present itself as a fresh install: the setup
    /// screen, and a fleet fetched rather than served from a stale cache.
    public static func shouldStartFresh(_ launch: Launch) -> Bool {
        switch launch {
        case .first, .reinstalled: return true
        case .upgraded, .unchanged: return false
        }
    }
}
