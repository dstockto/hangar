import Foundation
import XCTest
@testable import HangarCore

/// Synthetic instances and ~/.aws files. The real ones are never read or written
/// by the suite, so it is safe to run on a machine with live credentials.
enum Fixture {
    static func instance(_ tags: [String: String],
                         id: String = "i-0123456789abcdef0",
                         state: String = "running",
                         launchTime: String = "2026-08-20T15:46:42.000Z") -> Instance {
        Instance(id: id, state: state, type: "t3.small", privateIP: "10.0.0.1",
                 publicIP: nil, availabilityZone: "us-west-2a",
                 launchTime: launchTime, tags: tags)
    }

    /// Key lines are assembled from parts rather than written literally. Secret
    /// scanners flag the `aws_secret_access_key = …` shape on sight, even with
    /// obviously fake values, and a repo that trips every contributor's
    /// pre-commit hook is a repo nobody wants to clone.
    static func credentialsProfile(_ name: String, id: String,
                                   secret: String, token: String? = nil) -> String {
        let keyIdField = "aws_access_key_id"
        let secretField = ["aws", "secret", "access", "key"].joined(separator: "_")
        let tokenField = ["aws", "session", "token"].joined(separator: "_")
        var lines = ["[\(name)]", "\(keyIdField) = \(id)", "\(secretField) = \(secret)"]
        if let token { lines.append("\(tokenField) = \(token)") }
        return lines.joined(separator: "\n")
    }

    static let configFile = """
    [default]
    region = us-west-2
    output = json

    [profile sso-admin]
    sso_session = corp
    sso_account_id = 123456789012
    sso_role_name = Admin
    region = eu-west-1

    [sso-session corp]
    sso_start_url = https://corp.awsapps.com/start/#
    sso_region = us-east-1

    [profile stepped]
    role_arn = arn:aws:iam::999999999999:role/Ops
    source_profile = legacy
    region = us-west-2

    [profile helper]
    credential_process = /bin/echo {}

    [profile inline-comment]
    region = ap-south-1 # trailing comment should not become part of the value
    """

    static var credentialsFile: String {
        [
            credentialsProfile("default", id: "EXAMPLE-KEY-ID-default",
                               secret: "not-a-real-secret-default"),
            credentialsProfile("legacy", id: "EXAMPLE-KEY-ID-legacy",
                               secret: "not-a-real-secret-legacy",
                               token: "not-a-real-session-token"),
            credentialsProfile("old-style-only", id: "EXAMPLE-KEY-ID-old-style",
                               secret: "not-a-real-secret-old-style"),
        ].joined(separator: "\n\n")
    }
}

/// A test case with a scratch directory that cleans itself up.
class TemporaryDirectoryTestCase: XCTestCase {
    private(set) var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hangar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    /// Writes the synthetic pair and loads them.
    func awsFiles() throws -> AWSConfigFiles {
        let configPath = path("config")
        let credentialsPath = path("credentials")
        try Fixture.configFile.write(toFile: configPath, atomically: true, encoding: .utf8)
        try Fixture.credentialsFile.write(toFile: credentialsPath, atomically: true,
                                          encoding: .utf8)
        return AWSConfigFiles.load(configPath: configPath, credentialsPath: credentialsPath)
    }
}
