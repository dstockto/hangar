import XCTest
@testable import HangarCore

/// The Include line is the one line Hangar adds to a file that is not its own,
/// so how and when it lands is pinned here. Every case runs against temporary
/// files; nothing in this suite touches a real ~/.ssh/config.
final class IncludeLineTests: XCTestCase {

    private var scratch: String!

    override func setUpWithError() throws {
        scratch = NSTemporaryDirectory() + "/hangar-include-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    private func writer() -> SSHConfigWriter {
        SSHConfigWriter(config: HangarConfig.standard())
    }

    private func hosts() -> [Instance] {
        [Fixture.instance(["product": "payments", "env": "prod", "Name": "web",
                           "hostname": "web-1.prod.example.com"])]
    }

    private func userConfig(_ contents: String) throws -> String {
        let path = scratch + "/config"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testSyncAddsTheLineWhenAskedTo() throws {
        let userPath = try userConfig("Host bastion\n  HostName 10.0.0.1\n")
        let result = try writer().sync(instances: hosts(), region: "us-west-2",
                                       to: scratch + "/hangar",
                                       ensuringInclude: true, includePath: userPath)
        XCTAssertTrue(result.includeLineAdded)
        XCTAssertFalse(result.includeLineNeeded)
        let text = try String(contentsOfFile: userPath, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(SSHConfigWriter.includeLine), text)
        XCTAssertTrue(text.contains("Host bastion"), "the user's own content stays")
    }

    func testSyncLeavesTheFileAloneWhenNotAskedTo() throws {
        let original = "Host bastion\n  HostName 10.0.0.1\n"
        let userPath = try userConfig(original)
        let result = try writer().sync(instances: hosts(), region: "us-west-2",
                                       to: scratch + "/hangar",
                                       ensuringInclude: false, includePath: userPath)
        XCTAssertFalse(result.includeLineAdded)
        XCTAssertTrue(result.includeLineNeeded)
        XCTAssertEqual(try String(contentsOfFile: userPath, encoding: .utf8), original)
    }

    func testASecondSyncChangesNothing() throws {
        let userPath = try userConfig("Host bastion\n")
        _ = try writer().sync(instances: hosts(), region: "us-west-2",
                              to: scratch + "/hangar",
                              ensuringInclude: true, includePath: userPath)
        let afterFirst = try String(contentsOfFile: userPath, encoding: .utf8)
        let second = try writer().sync(instances: hosts(), region: "us-west-2",
                                       to: scratch + "/hangar",
                                       ensuringInclude: true, includePath: userPath)
        XCTAssertFalse(second.includeLineAdded, "it was already there")
        XCTAssertFalse(second.includeLineNeeded)
        XCTAssertEqual(try String(contentsOfFile: userPath, encoding: .utf8), afterFirst,
                       "byte for byte")
    }

    func testTheLineLandsAboveACatchAllHostBlock() throws {
        // ssh_config is first match wins per keyword, so an Include below a
        // Host * block would lose to it for every alias Hangar writes.
        let userPath = try userConfig("Host *\n  User someone\n")
        _ = try writer().sync(instances: hosts(), region: "us-west-2",
                              to: scratch + "/hangar",
                              ensuringInclude: true, includePath: userPath)
        let lines = try String(contentsOfFile: userPath, encoding: .utf8)
            .components(separatedBy: .newlines)
        let include = lines.firstIndex { $0.contains("config.d/hangar") }
        let catchAll = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "Host *" }
        XCTAssertNotNil(include)
        XCTAssertNotNil(catchAll)
        XCTAssertLessThan(include ?? .max, catchAll ?? 0)
    }

    func testAConfigWithoutATrailingNewlineSurvives() throws {
        let userPath = try userConfig("Host bastion\n  HostName 10.0.0.1")
        _ = try writer().sync(instances: hosts(), region: "us-west-2",
                              to: scratch + "/hangar",
                              ensuringInclude: true, includePath: userPath)
        let text = try String(contentsOfFile: userPath, encoding: .utf8)
        XCTAssertTrue(text.contains("  HostName 10.0.0.1"))
        XCTAssertEqual(text.components(separatedBy: "HostName").count - 1, 1,
                       "the line is not duplicated")
    }

    func testTheEditedFileStaysPrivateAndIsBackedUp() throws {
        let userPath = try userConfig("Host bastion\n")
        _ = try writer().sync(instances: hosts(), region: "us-west-2",
                              to: scratch + "/hangar",
                              ensuringInclude: true, includePath: userPath)
        let mode = (try FileManager.default
            .attributesOfItem(atPath: userPath)[.posixPermissions]) as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
        XCTAssertEqual(try String(contentsOfFile: userPath + ".hangar-backup",
                                  encoding: .utf8), "Host bastion\n")
    }

    func testTheDefaultConfigManagesTheIncludeLine() {
        XCTAssertEqual(HangarConfig.standard().manageSSHInclude, true)
    }
}
