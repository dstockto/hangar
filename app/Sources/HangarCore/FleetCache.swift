import Foundation

/// The fleet as it was written to disk on the last successful refresh.
///
/// UI-free and public because the menubar app is no longer the only reader: the
/// `hangar` command line reads exactly this file, and a second decoder with its
/// own idea of the format would be two answers to one question.
///
/// It holds the whole inventory, ids and private addresses and every tag, so it
/// is written through `PrivateFile` at 0600 like everything else under
/// `~/.hangar`.
public struct FleetCache: Codable, Sendable {
    public var instances: [Instance]
    public var region: String
    public var fetchedAt: Date
    /// The fleet's real tag keys, captured before normalization. Persisted so the
    /// setup screen can offer them without waiting for a refresh.
    public var tagCatalog: TagCatalog?
    /// A short history of host counts, one per successful refresh, so the
    /// dashboard can say "223 to 209 since 14:02" rather than only what is true
    /// this second. Optional, because a cache written before this existed has to
    /// keep decoding.
    public var history: [FleetSample]?

    public init(instances: [Instance], region: String, fetchedAt: Date,
                tagCatalog: TagCatalog? = nil, history: [FleetSample]? = nil) {
        self.instances = instances
        self.region = region
        self.fetchedAt = fetchedAt
        self.tagCatalog = tagCatalog
        self.history = history
    }

    /// About a day and a half at the default refresh, and a few hundred bytes.
    public static let historyLimit = 60

    /// Reads the cache, or nil when there is not one to read. A missing cache is
    /// not an error: it is a Hangar that has not refreshed yet, and the caller
    /// says what that means better than this can.
    public static func load(path: String = HangarConfig.cachePath) -> FleetCache? {
        guard let data = FileManager.default.contents(atPath: path),
              let cache = try? JSONDecoder().decode(FleetCache.self, from: data)
        else { return nil }
        return cache
    }

    @discardableResult
    public func write(to path: String = HangarConfig.cachePath) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return PrivateFile.write(data, to: path)
    }

    /// How old the cache is, in seconds.
    public var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
}

public struct FleetSample: Codable, Equatable, Sendable {
    public var at: Date
    public var hosts: Int

    public init(at: Date, hosts: Int) {
        self.at = at
        self.hosts = hosts
    }
}
