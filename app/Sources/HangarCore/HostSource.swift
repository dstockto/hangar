import Foundation

/// Where a host came from.
///
/// Hangar started with one source and three assumptions around it: EC2 read
/// access, the current user's login, and a key file in the home directory. This
/// is the first of those undone. EC2 is now one source among four, and every
/// host carries the answer to "where did this come from", because that is the
/// first question anyone asks about a host they did not expect to see.
public enum HostSource: String, Codable, Sendable, CaseIterable {
    case ec2
    case ssm
    case sshConfig = "ssh_config"
    case hostsFile = "hosts_file"

    /// Whether Hangar writes this host into its own ssh_config include.
    ///
    /// False for `sshConfig`, and that is the whole design of the import: those
    /// hosts are already resolvable by ssh, so writing them again would put
    /// Hangar's copy above the user's own definition and win, silently, on a
    /// file they wrote by hand.
    public var writesSSHConfig: Bool { self != .sshConfig }

    public var label: String {
        switch self {
        case .ec2:        return "EC2"
        case .ssm:        return "Systems Manager"
        case .sshConfig:  return "~/.ssh/config"
        case .hostsFile:  return "~/.hangar/hosts.csv"
        }
    }

    /// What the source needs to work, for the setup screen.
    public var requirement: String {
        switch self {
        case .ec2:        return "ec2:DescribeInstances"
        case .ssm:        return "ssm:DescribeInstanceInformation"
        case .sshConfig:  return "nothing; read from your home directory"
        case .hostsFile:  return "a CSV you drop on the window"
        }
    }

    /// An SF Symbol per source, for the row badge.
    public var symbolName: String {
        switch self {
        case .ec2:        return "cloud"
        case .ssm:        return "gearshape.2"
        case .sshConfig:  return "doc.text"
        case .hostsFile:  return "tablecells"
        }
    }
}

/// Which sources to gather from. All four default on: a source that finds
/// nothing costs nothing, and a source the user has to discover is a source they
/// never turn on.
public struct SourceSettings: Codable, Sendable, Equatable {
    public var ec2: Bool?
    /// Nil means "only when EC2 is denied", which is the default and the reason
    /// an under-permissioned account gets a fleet without being told the name of
    /// the API that refused it.
    public var ssm: Bool?
    public var sshConfig: Bool?
    public var hostsFile: Bool?

    enum CodingKeys: String, CodingKey {
        case ec2, ssm
        case sshConfig = "ssh_config"
        case hostsFile = "hosts_file"
    }

    public init(ec2: Bool? = nil, ssm: Bool? = nil,
                sshConfig: Bool? = nil, hostsFile: Bool? = nil) {
        self.ec2 = ec2
        self.ssm = ssm
        self.sshConfig = sshConfig
        self.hostsFile = hostsFile
    }

    public static let standard = SourceSettings()

    public var wantsEC2: Bool { ec2 ?? true }
    public var wantsSSHConfig: Bool { sshConfig ?? true }
    public var wantsHostsFile: Bool { hostsFile ?? true }
    /// True when SSM was asked for outright. A nil is answered by
    /// `wantsSSMAfterFailure`, which is the case that needs to know what EC2 did.
    public var wantsSSMAlways: Bool { ssm == true }
    public var wantsSSMAfterFailure: Bool { ssm ?? true }
}

/// What one source produced, kept per source so the setup screen can say which
/// of them worked rather than only how many hosts turned up.
public struct SourceReport: Sendable, Equatable {
    public var source: HostSource
    public var hosts: Int
    /// Rows or blocks the source could not use, already worded for a person.
    public var skipped: [String]
    /// Why the source produced nothing, when that was a failure rather than an
    /// empty answer.
    public var problem: String?
    /// False when the source was switched off or never applied.
    public var attempted: Bool

    public init(source: HostSource, hosts: Int = 0, skipped: [String] = [],
                problem: String? = nil, attempted: Bool = true) {
        self.source = source
        self.hosts = hosts
        self.skipped = skipped
        self.problem = problem
        self.attempted = attempted
    }

    public static func off(_ source: HostSource) -> SourceReport {
        SourceReport(source: source, attempted: false)
    }
}

/// Folds several sources into one fleet.
public enum FleetMerge {
    /// Priority, richest first. EC2 knows the most about a host, so when two
    /// sources describe the same machine the EC2 copy is the one that keeps its
    /// tags, its state and its dashboard data.
    public static let priority: [HostSource] = [.ec2, .ssm, .hostsFile, .sshConfig]

    public struct Merged: Sendable {
        public var instances: [Instance]
        /// Hosts dropped because a higher-priority source already had them.
        public var duplicates: Int
    }

    /// A host is a duplicate of one already taken when it matches on instance id,
    /// on the hostname it resolves to, or on a name it was *given*. Three keys
    /// rather than one because the sources name the same machine three different
    /// ways: EC2 by id, a CSV by alias, an ssh config by address.
    ///
    /// The name key is `preferredAlias`, never the derived `aliasStem`. Two
    /// members of one autoscaling group share a stem by design, and the writer
    /// exists to number them apart; matching on the stem here dropped 18 real
    /// hosts out of a 223-instance fleet on the first run against a live account,
    /// silently, which is the one thing this codebase does not do.
    public static func merge(_ groups: [HostSource: [Instance]]) -> Merged {
        var taken: [Instance] = []
        var ids = Set<String>()
        var hosts = Set<String>()
        var names = Set<String>()
        var duplicates = 0

        for source in priority {
            for var instance in groups[source] ?? [] {
                instance.source = source
                let host = instance.host?.lowercased()
                let name = instance.preferredAlias?.lowercased()
                let isDuplicate = ids.contains(instance.id)
                    || (host.map { hosts.contains($0) } ?? false)
                    || (name.map { names.contains($0) } ?? false)
                if isDuplicate {
                    duplicates += 1
                    continue
                }
                ids.insert(instance.id)
                if let host { hosts.insert(host) }
                if let name { names.insert(name) }
                taken.append(instance)
            }
        }
        return Merged(instances: taken, duplicates: duplicates)
    }
}
