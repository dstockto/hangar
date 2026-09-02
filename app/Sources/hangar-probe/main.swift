import Foundation
import HangarCore

// Verification harness for the credential chain and the EC2 call. The app proper
// uses the same HangarCore entry points.
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
    var args = Array(CommandLine.arguments.dropFirst())
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
