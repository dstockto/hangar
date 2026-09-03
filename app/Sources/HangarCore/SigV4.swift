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

    /// The query protocol most of AWS still speaks, and the one EC2 and STS use.
    public static let formContentType = "application/x-www-form-urlencoded; charset=utf-8"
    /// AWS JSON 1.1, which SSM speaks. It needs `x-amz-target` alongside it, and
    /// that header has to be signed or the signature is rejected.
    public static let jsonContentType = "application/x-amz-json-1.1"

    /// Returns a request signed with the Authorization header form of SigV4.
    ///
    /// `extraHeaders` are signed as well as sent. Anything AWS requires on the
    /// wire belongs in the canonical headers; a header sent but not signed is a
    /// 403 with a signature mismatch and no clue as to which header caused it.
    public func sign(url: URL, body: String,
                     contentType: String = SigV4.formContentType,
                     extraHeaders: [String: String] = [:],
                     now: Date = Date()) -> URLRequest {
        let amzDate = SigV4.stamp(now, format: "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = SigV4.stamp(now, format: "yyyyMMdd")
        let host = url.host ?? ""
        let payloadHash = SigV4.sha256Hex(Data(body.utf8))

        var headers: [(String, String)] = [
            ("content-type", contentType),
            ("host", host),
            ("x-amz-date", amzDate),
        ]
        for (name, value) in extraHeaders {
            headers.append((name.lowercased(), value))
        }
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
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
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
