import Foundation

/// Where a given set of credentials came from. Shown in the UI so the user can
/// tell at a glance whether they are on SSO, a static key pair, or an assumed role.
public enum CredentialSource: Sendable, Equatable {
    case environment
    case staticKeys(profile: String)
    case sso(profile: String)
    case assumedRole(profile: String, arn: String)
    case credentialProcess(profile: String)

    public var label: String {
        switch self {
        case .environment:                 return "environment variables"
        case .staticKeys(let p):           return "static keys in profile \(p)"
        case .sso(let p):                  return "SSO profile \(p)"
        case .assumedRole(let p, let arn): return "profile \(p) assuming \(arn)"
        case .credentialProcess(let p):    return "credential_process in profile \(p)"
        }
    }
}

public struct ResolvedCredentials: Sendable {
    public var credentials: AWSCredentials
    public var source: CredentialSource
    public var region: String
}

/// Resolves credentials in the same precedence order the AWS CLI uses, covering
/// every profile style Hangar is likely to meet: environment variables, static
/// keys in ~/.aws/credentials, SSO, an assumed role via source_profile, and
/// credential_process. Nothing here needs the aws CLI on PATH.
public enum CredentialResolver {

    public static func resolve(
        profile requested: String? = nil,
        files: AWSConfigFiles? = nil,
        depth: Int = 0
    ) async throws -> ResolvedCredentials {
        guard depth < 5 else {
            throw HangarError.noProfile("source_profile chain is too deep or loops")
        }
        let env = ProcessInfo.processInfo.environment
        let files = files ?? AWSConfigFiles.load()

        // Environment variables win, but only when the caller has not asked for a
        // specific profile. Otherwise an exported key pair would silently shadow
        // whichever profile the user just picked in the menu.
        if requested == nil,
           let key = env["AWS_ACCESS_KEY_ID"], !key.isEmpty,
           let secret = env["AWS_SECRET_ACCESS_KEY"], !secret.isEmpty {
            return ResolvedCredentials(
                credentials: AWSCredentials(
                    accessKeyId: key, secretAccessKey: secret,
                    sessionToken: env["AWS_SESSION_TOKEN"], expiration: nil),
                source: .environment,
                region: env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] ?? "us-east-1")
        }

        let profile = try files.profile(named: requested)

        if profile.hasStaticKeys {
            return ResolvedCredentials(
                credentials: AWSCredentials(
                    accessKeyId: profile.accessKeyId!,
                    secretAccessKey: profile.secretAccessKey!,
                    sessionToken: profile.sessionToken,
                    expiration: nil),
                source: .staticKeys(profile: profile.name),
                region: profile.region)
        }

        if profile.isSSO {
            let credentials = try await SSO.credentials(for: profile)
            return ResolvedCredentials(
                credentials: credentials,
                source: .sso(profile: profile.name),
                region: profile.region)
        }

        if profile.assumesRole {
            let sourceName = profile.sourceProfile ?? "default"
            let base = try await resolve(profile: sourceName, files: files, depth: depth + 1)
            let assumed = try await STS.assumeRole(
                using: base.credentials,
                region: profile.region,
                roleArn: profile.roleArn!,
                sessionName: profile.roleSessionName ?? "hangar",
                externalId: profile.externalId)
            return ResolvedCredentials(
                credentials: assumed,
                source: .assumedRole(profile: profile.name, arn: profile.roleArn!),
                region: profile.region)
        }

        if let command = profile.credentialProcess, !command.isEmpty {
            return ResolvedCredentials(
                credentials: try runCredentialProcess(command),
                source: .credentialProcess(profile: profile.name),
                region: profile.region)
        }

        throw HangarError.noProfile(
            "profile '\(profile.name)' has no credentials Hangar can use. "
            + "It needs either aws_access_key_id and aws_secret_access_key, "
            + "SSO settings, role_arn with source_profile, or credential_process.")
    }

    /// credential_process is the user's own configured helper, so running it is
    /// honouring their setup rather than adding a dependency of our own.
    static func runCredentialProcess(_ command: String) throws -> AWSCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HangarError.malformedResponse(
                "credential_process exited \(process.terminationStatus)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["AccessKeyId"] as? String,
              let secret = obj["SecretAccessKey"] as? String else {
            throw HangarError.malformedResponse("credential_process returned unusable JSON")
        }
        var expiry: Date?
        if let raw = obj["Expiration"] as? String {
            expiry = ISO8601DateFormatter().date(from: raw)
        }
        return AWSCredentials(
            accessKeyId: key, secretAccessKey: secret,
            sessionToken: obj["SessionToken"] as? String, expiration: expiry)
    }
}

public enum STS {
    public static func assumeRole(
        using base: AWSCredentials, region: String, roleArn: String,
        sessionName: String, externalId: String? = nil
    ) async throws -> AWSCredentials {
        var params = [
            "Action": "AssumeRole",
            "Version": "2011-06-15",
            "RoleArn": roleArn,
            "RoleSessionName": sessionName,
        ]
        if let externalId, !externalId.isEmpty { params["ExternalId"] = externalId }
        let body = params.keys.sorted()
            .map { "\(percentEncode($0))=\(percentEncode(params[$0]!))" }
            .joined(separator: "&")

        let url = try AWSRegion.endpoint(service: "sts", region: region)
        let signer = SigV4(credentials: base, region: region, service: "sts")
        let (data, response) = try await HangarHTTP.session.data(for: signer.sign(url: url, body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let xml = String(data: data, encoding: .utf8) ?? ""
        guard code == 200 else {
            throw HangarError.http(code, element("Message", in: xml) ?? xml)
        }
        guard let key = element("AccessKeyId", in: xml),
              let secret = element("SecretAccessKey", in: xml) else {
            throw HangarError.malformedResponse("no credentials in AssumeRole response")
        }
        var expiry: Date?
        if let raw = element("Expiration", in: xml) {
            expiry = ISO8601DateFormatter().date(from: raw)
        }
        return AWSCredentials(
            accessKeyId: key, secretAccessKey: secret,
            sessionToken: element("SessionToken", in: xml), expiration: expiry)
    }

    static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>"),
              open.upperBound <= close.lowerBound else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
