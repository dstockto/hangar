import Foundation
import CryptoKit

/// AWS Signature Version 4 for a single POST to a query-protocol endpoint.
/// Hand-rolled on purpose: Hangar makes exactly one signed call, so pulling in
/// the AWS SDK would dominate build time and binary size for no benefit.
public struct SigV4 {
    public let credentials: AWSCredentials
    public let region: String
    public let service: String

    public init(credentials: AWSCredentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// Returns a request signed with the Authorization header form of SigV4.
    public func sign(url: URL, body: String, now: Date = Date()) -> URLRequest {
        let amzDate = SigV4.stamp(now, format: "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = SigV4.stamp(now, format: "yyyyMMdd")
        let host = url.host ?? ""
        let payloadHash = SigV4.sha256Hex(Data(body.utf8))
        let contentType = "application/x-www-form-urlencoded; charset=utf-8"

        var headers: [(String, String)] = [
            ("content-type", contentType),
            ("host", host),
            ("x-amz-date", amzDate),
        ]
        if let token = credentials.sessionToken, !token.isEmpty {
            headers.append(("x-amz-security-token", token))
        }
        headers.sort { $0.0 < $1.0 }

        let canonicalHeaders = headers
            .map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            "POST",
            url.path.isEmpty ? "/" : url.path,
            "",                       // no query string; everything is in the body
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            SigV4.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var signingKey = Data("AWS4\(credentials.secretAccessKey)".utf8)
        for step in [dateStamp, region, service, "aws4_request"] {
            signingKey = SigV4.hmac(signingKey, step)
        }
        let signature = SigV4.hmac(signingKey, stringToSign)
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        return request
    }

    private static func stamp(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
