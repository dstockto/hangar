import Foundation
import HangarCore

// Verification harness for the credential chain and the EC2 call. The app proper
// uses the same HangarCore entry points.
//
// The local subcommands need no credentials and no network, which is the point:
// they are the sources an SRE with no AWS permission at all still has.

/// Every local source, printed. `HANGAR_HOME` and `HOME` are honoured by the
/// paths underneath, so this can be pointed at a fabricated home directory.
func reportLocalSources() {
    print("ssh config  : \(SSHConfigWriter.userConfigPath)")
    let imported = SSHConfigImport.load()
    print("  hosts     : \(imported.hosts.count)")
    for host in imported.hosts.prefix(8) {
        print(String(format: "    %-34s %-18s %@",
                     (host.aliasStem as NSString).utf8String!,
                     ((host.product.isEmpty ? "-" : host.product) as NSString).utf8String!,
                     host.host ?? "-"))
    }
    for note in imported.skipped.prefix(5) { print("    skipped: \(note)") }

    print("hosts file  : \(HangarConfig.hostsFilePath)")
    let file = HostsFile.load()
    print("  hosts     : \(file.hosts.count)")
    for host in file.hosts.prefix(8) {
        print(String(format: "    %-34s %-18s %@",
                     (host.aliasStem as NSString).utf8String!,
                     ((host.product.isEmpty ? "-" : host.product) as NSString).utf8String!,
                     host.host ?? "-"))
    }
    for note in file.skipped.prefix(5) { print("    skipped: \(note)") }

    let merged = FleetMerge.merge([.sshConfig: imported.hosts, .hostsFile: file.hosts])
    print("merged      : \(merged.instances.count) hosts, \(merged.duplicates) duplicates")

    let writer = SSHConfigWriter(config: (try? HangarConfig.load()) ?? .standard())
    print("written     : \(writer.entries(for: merged.instances).count) "
          + "of \(merged.instances.count) "
          + "(imported hosts are launch-only and stay out of the file)")
}

/// The agents on this machine and what they are holding. Reads no private key
/// and unlocks nothing.
func reportKeys() {
    for candidate in KeySource.knownSockets() {
        let exists = FileManager.default.fileExists(atPath: candidate.socket)
        print("\(candidate.kind.name.padding(toLength: 15, withPad: " ", startingAt: 0)): "
              + "\(exists ? "socket present" : "no socket")  \(candidate.socket)")
    }
    for agent in KeySource.detectAgents() {
        print("\n\(agent.name) at \(agent.socket)")
        if let problem = agent.problem { print("  problem   : \(problem)") }
        for key in agent.keys {
            print("  \(key.algorithm.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                  + "\(key.title)   -> ~/.hangar/keys/\(key.slug).pub")
        }
    }
    let files = KeySource.detectKeyFiles()
    print("\nkey files   : \(files.isEmpty ? "none in ~/.ssh" : files.joined(separator: ", "))")
}

/// Drives every source, the merge and the writer against a fabricated home
/// directory, and reports what came out.
///
/// Every path is explicit. `expandingTildeInPath` reads the real home on macOS
/// whatever `HOME` says, so a testbed built on an environment variable would
/// quietly read and rewrite the developer's own ssh config. Passing the paths in
/// is the only way this is provably harmless.
func runTestbed(root: String) -> Int32 {
    func path(_ parts: String...) -> String {
        parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
    }
    var failures = 0
    func check(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    print("testbed root: \(root)\n")

    // 1. The user's own ssh config, imported and never written back.
    print("ssh config import")
    let imported = SSHConfigImport.load(path: path(".ssh", "config"),
                                        excluding: path(".ssh", "config.d", "hangar"))
    print("  \(imported.hosts.count) hosts, \(imported.skipped.count) skipped")
    for note in imported.skipped { print("    skipped: \(note)") }
    check(!imported.hosts.isEmpty, "hosts were found")
    check(!imported.hosts.contains { $0.aliasStem.contains("*") },
          "no pattern was imported as a host")
    check(imported.hosts.allSatisfy { $0.origin == .sshConfig }, "every host is stamped")
    check(imported.hosts.contains { $0.env == "prod" }, "env came from a known word")
    check(imported.hosts.contains { !$0.product.isEmpty }, "a shared prefix became a product")
    check(imported.hosts.contains { $0.tags["ssh_config_user"] != nil },
          "an imported login was kept rather than guessed")
    check(!imported.hosts.contains { $0.aliasStem.contains("github")
              || $0.aliasStem == "bitbucket.org" || $0.aliasStem == "work-gitlab" },
          "git remotes were not imported as hosts")
    check(imported.skipped.filter { $0.contains("git remote") }.count == 3,
          "and each one said why")
    check(imported.hosts.contains { $0.aliasStem == "git-runner-1" },
          "a machine merely named for git is still a host")

    // 2. A CSV, good rows and bad ones.
    print("\nhosts file")
    let file = HostsFile.load(path: path(".hangar", "hosts.csv"))
    print("  \(file.hosts.count) hosts, \(file.skipped.count) skipped")
    for note in file.skipped { print("    skipped: \(note)") }
    check(!file.hosts.isEmpty, "hosts were found")
    check(!file.skipped.isEmpty, "the deliberately bad rows were refused")
    check(file.skipped.allSatisfy { $0.contains("line ") }, "every refusal names its line")
    check(!file.hosts.contains { $0.aliasStem == "*" }, "a catch-all alias was refused")

    // 3. A synthetic EC2 page, so the merge has a richest source to prefer.
    let ec2 = [
        Instance(id: "i-0aaaaaaaaaaaaaaaa", state: "running", type: "m6i.large",
                 privateIP: "10.0.1.10", publicIP: nil, availabilityZone: "us-west-2a",
                 launchTime: "2026-06-01T00:00:00.000Z",
                 tags: ["product": "payments", "env": "prod", "Name": "web",
                        "hostname": "payments-prod-web.example.com"]),
        // The same machine the ssh config also names, by address.
        Instance(id: "i-0bbbbbbbbbbbbbbbb", state: "running", type: "m6i.large",
                 privateIP: "10.0.1.11", publicIP: nil, availabilityZone: "us-west-2b",
                 launchTime: "2026-06-01T00:00:00.000Z",
                 tags: ["product": "payments", "env": "prod", "Name": "db",
                        "hostname": "10.20.30.40"]),
    ]

    print("\nmerge")
    let merged = FleetMerge.merge([.ec2: ec2, .hostsFile: file.hosts,
                                   .sshConfig: imported.hosts])
    print("  \(merged.instances.count) hosts, \(merged.duplicates) duplicates dropped")
    check(merged.duplicates > 0, "the host two sources both named was merged")
    check(merged.instances.filter { $0.host == "10.20.30.40" }.first?.origin == .ec2,
          "the EC2 copy won, so it kept its tags and its zone")
    let aliases = merged.instances.map(\.aliasStem)
    check(Set(aliases).count == aliases.count, "no two hosts share an alias")

    // 4. The file Hangar writes, validated by ssh itself.
    print("\nssh_config written")
    let config = HangarConfig.standard()
    let writer = SSHConfigWriter(config: config)
    let target = path(".ssh", "config.d", "hangar")
    do {
        let result = try writer.sync(instances: merged.instances, region: "us-west-2",
                                     to: target, ensuringInclude: true,
                                     includePath: path(".ssh", "config"))
        print("  \(result.hostCount) aliases at \(result.path)")
        check(result.hostCount > 0, "aliases were written")
        check(result.includeLineAdded || !result.includeLineNeeded, "the Include line is in place")
        let text = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        check(!imported.hosts.isEmpty && !imported.hosts.contains { text.contains("Host \($0.aliasStem)\n") },
              "not one imported host was written back")
        check(text.contains("source=hosts_file"), "CSV hosts say where they came from")
        check(SSHConfigWriter.validate(target) == nil, "ssh itself parses the result")
        let mode = (try? FileManager.default.attributesOfItem(atPath: target)[.posixPermissions]
                        as? Int) ?? 0
        check(mode == 0o600, "the file is 0600")
    } catch {
        check(false, "sync failed: \(error.localizedDescription)")
    }

    // 5. Key emission, without needing an agent to be running.
    print("\nkey source")
    var agentConfig = HangarConfig.standard()
    agentConfig.ssh?.identityAgent = KeySource.onePasswordSocket
    agentConfig.ssh?.identityFile = "~/.hangar/keys/prod-sre-abcd1234.pub"
    agentConfig.ssh?.identitiesOnly = true
    let agentText = SSHConfigWriter(config: agentConfig)
        .render(instances: ec2, region: "us-west-2")
    check(agentText.contains("IdentityAgent \"\(KeySource.onePasswordSocket)\""),
          "the agent socket is quoted, because its path has a space in it")
    check(agentText.contains("IdentitiesOnly yes"), "the agent is narrowed to one key")
    var looseConfig = HangarConfig.standard()
    looseConfig.ssh?.identityFile = "~/.ssh/id_rsa"
    looseConfig.ssh?.identitiesOnly = false
    check(!SSHConfigWriter(config: looseConfig)
        .render(instances: ec2, region: "us-west-2").contains("IdentitiesOnly"),
          "a pinned key no longer forces the agent out")

    print("\n\(failures == 0 ? "testbed passed" : "testbed FAILED: \(failures) check(s)")")
    return failures == 0 ? 0 : 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--testbed", arguments.count > 1 {
    exit(runTestbed(root: arguments[1]))
}
if arguments.first == "--keys" {
    reportKeys()
    exit(0)
}
if arguments.first == "--sources" {
    reportLocalSources()
    exit(0)
}

let started = Date()
do {
    let files = AWSConfigFiles.load()
    print("profiles    : \(files.profileNames.joined(separator: ", "))")

    let profile = try files.profile()
    print("using       : \(profile.name)  region=\(profile.region)")

    if profile.isSSO, let startURL = profile.ssoStartURL {
        let token = try SSO.findToken(startURL: startURL)
        print("sso token   : \(URL(fileURLWithPath: token.path).lastPathComponent) expires=\(token.expiresAt) expired=\(token.isExpired)")
    }

    let resolved = try await CredentialResolver.resolve()
    print("source      : \(resolved.source.label)")
    print("credentials : \(resolved.credentials.accessKeyId.prefix(5))... expires=\(resolved.credentials.expiration?.description ?? "never")")

    if profile.isSSO, let startURL = profile.ssoStartURL {
        let after = try SSO.findToken(startURL: startURL)
        print("token after : expires=\(after.expiresAt) expired=\(after.isExpired)")
    }

    let credentials = resolved.credentials
    let ec2 = EC2(credentials: credentials, region: resolved.region)
    var filters: [EC2.Filter] = []
    var args = arguments
    while args.count >= 2 {
        filters.append(EC2.Filter(name: "tag:\(args[0])", values: [args[1]]))
        args = Array(args.dropFirst(2))
    }
    filters.append(EC2.Filter(
        name: "instance-state-name",
        values: ["pending", "running", "stopping", "stopped"]))

    let instances = try await ec2.describeInstances(filters: filters)
    print("instances   : \(instances.count) in \(String(format: "%.2fs", -started.timeIntervalSinceNow))\n")

    for instance in instances
        .sorted(by: { ($0.product, $0.env, $0.aliasStem) < ($1.product, $1.env, $1.aliasStem) })
        .prefix(12) {
        print(String(format: "%-34s %-12s %-9s %-8s %@",
                     (instance.aliasStem as NSString).utf8String!,
                     (instance.id as NSString).utf8String!,
                     (instance.state as NSString).utf8String!,
                     (instance.isASG ? "ASG" : "-" as NSString).utf8String!,
                     instance.host ?? "-"))
    }
    let byEnv = Dictionary(grouping: instances, by: \.env)
        .mapValues(\.count).sorted { $0.key < $1.key }
    print("\nby env      : " + byEnv.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
} catch {
    print("FAILED: \(error.localizedDescription)")
    exit(1)
}
