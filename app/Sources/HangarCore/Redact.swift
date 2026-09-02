import CryptoKit
import Foundation

/// Short stable digests for anything that names someone's infrastructure.
///
/// The log has to be safe to paste into a public issue without reading it line
/// by line first, and it also has to be useful, which means two lines about the
/// same host have to be tied together. A digest does both: `host#4f2a` is the
/// same host every time and is not a hostname.
public enum Redact {
    public static func host(_ value: String) -> String {
        value.isEmpty ? "host#none" : "host#\(digest(value))"
    }

    public static func instance(_ id: String) -> String {
        id.isEmpty ? "i#none" : "i#\(digest(id))"
    }

    /// Four hex characters of SHA-256. Enough to correlate within a log, far too
    /// little to walk back to the original.
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(2)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
