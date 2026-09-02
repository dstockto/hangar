import Foundation

/// Resolves credentials the way the AWS CLI does, reading only files already in
/// the user's home directory, then refreshing the SSO token itself when it has
/// expired. Nothing here shells out.
public struct SSO {
    public struct CachedToken {
        public var path: String
        public var raw: [String: Any]
        public var accessToken: String
        public var expiresAt: Date
        public var refreshToken: String?
        public var clientId: String?
        public var clientSecret: String?
        public var region: String?

        public var isExpired: Bool { expiresAt.timeIntervalSinceNow < 120 }
    }

    /// A fresh formatter per use. ISO8601DateFormatter is not Sendable, and one
    /// shared instance would be mutable state reachable from any task; this is
    /// called a handful of times per token refresh, so the cost is nothing.
    static var iso: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// The AWS CLI names cache files by a hash we would rather not reimplement,
    /// so match on the startUrl inside each file instead.
    public static func findToken(
        startURL: String,
        cacheDir: String = NSString(string: "~/.aws/sso/cache").expandingTildeInPath
    ) throws -> CachedToken {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheDir) else {
            throw HangarError.noSSOToken("no \(cacheDir); has this machine ever run aws sso login?")
        }
        let wanted = startURL.trimmingCharacters(in: CharacterSet(charactersIn: "#/"))
        var candidates: [CachedToken] = []
        for name in names where name.hasSuffix(".json") {
            let path = (cacheDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["accessToken"] as? String,
                  let expiresRaw = obj["expiresAt"] as? String,
                  let expires = iso.date(from: expiresRaw)
            else { continue }
            let fileURL = (obj["startUrl"] as? String ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#/"))
            guard fileURL == wanted else { continue }
            candidates.append(CachedToken(
                path: path, raw: obj, accessToken: token, expiresAt: expires,
                refreshToken: obj["refreshToken"] as? String,
                clientId: obj["clientId"] as? String,
                clientSecret: obj["clientSecret"] as? String,
                region: obj["region"] as? String))
        }
        guard let best = candidates.max(by: { $0.expiresAt < $1.expiresAt }) else {
            throw HangarError.noSSOToken("nothing in \(cacheDir) matches \(startURL)")
        }
        return best
    }

    /// Trades the refresh token for a new access token and rewrites the cache file
    /// in the CLI's own format, so both tools stay in step.
    public static func refresh(_ token: CachedToken, region: String) async throws -> CachedToken {
        guard let refreshToken = token.refreshToken,
              let clientId = token.clientId,
              let clientSecret = token.clientSecret else {
            throw HangarError.ssoTokenExpired("token has no refresh material; run 'aws sso login'")
        }
        let url = try AWSRegion.endpoint(service: "oidc", region: region, path: "/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken,
        ])

        let (data, response) = try await HangarHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if code == 400 || code == 401 {
                throw HangarError.ssoTokenExpired(
                    "refresh was rejected; run 'aws sso login' to sign in again")
            }
            throw HangarError.http(code, body)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = obj["accessToken"] as? String else {
            throw HangarError.malformedResponse("no accessToken in OIDC refresh response")
        }
        let lifetime = (obj["expiresIn"] as? Int) ?? 28800
        let newExpiry = Date().addingTimeInterval(TimeInterval(lifetime))

        var raw = token.raw
        raw["accessToken"] = accessToken
        raw["expiresAt"] = iso.string(from: newExpiry)
        if let rotated = obj["refreshToken"] as? String { raw["refreshToken"] = rotated }
        if let out = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) {
            writeTokenCache(out, to: token.path)
        }

        var updated = token
        updated.raw = raw
        updated.accessToken = accessToken
        updated.expiresAt = newExpiry
        if let rotated = obj["refreshToken"] as? String { updated.refreshToken = rotated }
        return updated
    }

    /// Replaces the CLI's cache file without ever leaving the new token readable
    /// by anyone else. Writing with `.atomic` alone would create the temporary
    /// file at the process umask first and only tighten it afterwards, so the
    /// destination is created at 0600 up front and swapped in.
    static func writeTokenCache(_ data: Data, to path: String) {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".hangar-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else { return }
        do {
            try data.write(to: temporary)
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? fm.removeItem(at: temporary)
        }
    }

    /// Exchanges an SSO access token for short-lived role credentials.
    public static func roleCredentials(
        accessToken: String, region: String, accountId: String, roleName: String
    ) async throws -> AWSCredentials {
        let base = try AWSRegion.endpoint(service: "portal.sso", region: region,
                                          path: "/federation/credentials")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw HangarError.malformedResponse("could not build the SSO federation URL")
        }
        components.queryItems = [
            URLQueryItem(name: "account_id", value: accountId),
            URLQueryItem(name: "role_name", value: roleName),
        ]
        guard let url = components.url else {
            throw HangarError.malformedResponse(
                "account id or role name is not usable in a URL")
        }
        var request = URLRequest(url: url)
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")

        let (data, response) = try await HangarHTTP.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 || code == 403 {
                throw HangarError.ssoTokenExpired("SSO rejected the token for \(roleName)")
            }
            throw HangarError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = obj["roleCredentials"] as? [String: Any],
              let key = role["accessKeyId"] as? String,
              let secret = role["secretAccessKey"] as? String else {
            throw HangarError.malformedResponse("no roleCredentials in SSO response")
        }
        var expiry: Date?
        if let ms = role["expiration"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        }
        return AWSCredentials(
            accessKeyId: key, secretAccessKey: secret,
            sessionToken: role["sessionToken"] as? String, expiration: expiry)
    }

    /// The whole chain: profile in, usable credentials out.
    public static func credentials(for profile: AWSProfile) async throws -> AWSCredentials {
        guard profile.isSSO,
              let startURL = profile.ssoStartURL,
              let accountId = profile.ssoAccountId,
              let roleName = profile.ssoRoleName else {
            throw HangarError.noProfile(
                "profile '\(profile.name)' is not an SSO profile; Hangar needs sso_account_id and sso_role_name")
        }
        let ssoRegion = profile.ssoRegion ?? profile.region
        var token = try findToken(startURL: startURL)
        if token.isExpired {
            token = try await refresh(token, region: token.region ?? ssoRegion)
        }
        return try await roleCredentials(
            accessToken: token.accessToken, region: token.region ?? ssoRegion,
            accountId: accountId, roleName: roleName)
    }
}
