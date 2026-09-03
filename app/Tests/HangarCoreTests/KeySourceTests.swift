import XCTest
@testable import HangarCore

final class KeySourceTests: XCTestCase {

    // MARK: - Parsing what the agent says

    func testParsesOneKeyPerLineKeepingTheComment() {
        let keys = KeySource.parseKeyList("""
        ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGabcdefghij Prod SRE key
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCabcdefg Personal laptop
        """)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].algorithm, "ssh-ed25519")
        XCTAssertEqual(keys[0].comment, "Prod SRE key",
                       "a comment with spaces is one comment, not three")
        XCTAssertEqual(keys[1].title, "Personal laptop")
    }

    func testKeyWithNoCommentStillHasATitle() {
        let keys = KeySource.parseKeyList("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGabcdefghij")
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys[0].comment.isEmpty)
        XCTAssertFalse(keys[0].title.isEmpty, "an unnamed key still has to be pickable")
    }

    func testRejectsLinesThatAreNotKeys() {
        let keys = KeySource.parseKeyList("""
        The agent has no identities.

        # a comment
        ssh-ed25519 not base64 at all
        notanalgorithm AAAAC3NzaC1lZDI1NTE5AAAAIGabcdefghij name
        """)
        XCTAssertTrue(keys.isEmpty, "everything here reaches an ssh_config file")
    }

    /// The blob ends up quoted into a file ssh parses, so a line break in it
    /// would be a second directive.
    func testRejectsABlobThatCouldCarryADirective() {
        let keys = KeySource.parseKeyList("ssh-ed25519 AAAA\"B3Nza;evil AAAA name")
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - Slugs

    func testSlugIsFilenameSafeAndUniquePerKey() {
        let a = AgentKey(algorithm: "ssh-ed25519", blob: "AAAAC3NzaC1lZDI1NTE5aaaa11111",
                         comment: "Prod SRE key")
        let b = AgentKey(algorithm: "ssh-ed25519", blob: "AAAAC3NzaC1lZDI1NTE5bbbb22222",
                         comment: "Prod SRE key")
        XCTAssertTrue(a.slug.hasPrefix("prod-sre-key-"))
        XCTAssertNotEqual(a.slug, b.slug,
                          "two vault items can share a title; the file they name cannot")
        XCTAssertTrue(a.slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    func testSlugSurvivesAnUnprintableComment() {
        let key = AgentKey(algorithm: "ssh-ed25519", blob: "AAAAC3NzaC1lZDI1NTE5zzzz9999",
                           comment: "../../etc/authorized_keys")
        XCTAssertFalse(key.slug.contains("/"), "the slug becomes a filename")
        XCTAssertFalse(key.slug.contains(".."))
    }

    func testPublicKeyLineRoundTrips() {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGabcdefghij Prod SRE key"
        XCTAssertEqual(KeySource.parseKeyList(line).first?.publicKeyLine, line)
    }

    // MARK: - Detection

    func testDetectsNothingWhenNoSocketExists() {
        let agents = KeySource.detectAgents(
            candidates: [(.onePassword, "/nonexistent/hangar-test-1p.sock"),
                         (.environment, "/nonexistent/hangar-test-env.sock")],
            list: { _ in ([], nil) })
        XCTAssertTrue(agents.isEmpty,
                      "a machine with no agent should show no rows, not three empty ones")
    }

    func testDetectsAnAgentAtASocketThatExists() throws {
        let socket = NSTemporaryDirectory() + "hangar-agent-\(UUID().uuidString).sock"
        FileManager.default.createFile(atPath: socket, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let agents = KeySource.detectAgents(
            candidates: [(.onePassword, socket)],
            list: { _ in (KeySource.parseKeyList(
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGabcdefghij Prod SRE key"), nil) })
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].name, "1Password")
        XCTAssertTrue(agents[0].isUsable)
        XCTAssertEqual(agents[0].keys.first?.title, "Prod SRE key")
    }

    func testTheSameSocketUnderTwoNamesIsOneAgent() throws {
        let socket = NSTemporaryDirectory() + "hangar-agent-\(UUID().uuidString).sock"
        FileManager.default.createFile(atPath: socket, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let agents = KeySource.detectAgents(
            candidates: [(.onePassword, socket), (.environment, socket)],
            list: { _ in ([], nil) })
        XCTAssertEqual(agents.count, 1,
                       "SSH_AUTH_SOCK often points at the app's own socket")
    }

    func testTheKnownSocketListIncludesTheShellsOwn() {
        let sockets = KeySource.knownSockets(environment: ["SSH_AUTH_SOCK": "/tmp/mine.sock"])
        XCTAssertTrue(sockets.contains { $0.socket == "/tmp/mine.sock" })
        XCTAssertTrue(sockets.contains { $0.kind == .onePassword })
    }

    func testAnAgentWithNoKeysIsReportedRatherThanHidden() {
        // A locked vault and an empty one look identical from outside, and locked
        // is the likelier of the two.
        let agent = SSHAgent(kind: .onePassword, socket: "/tmp/x", keys: [],
                             problem: "No keys available.")
        XCTAssertFalse(agent.isUsable)
        XCTAssertNotNil(agent.problem)
    }

    func testKeyFileDetectionOnlyReportsWhatExists() {
        let directory = NSTemporaryDirectory() + "hangar-keys-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        FileManager.default.createFile(atPath: directory + "/id_ed25519", contents: Data())
        let found = KeySource.detectKeyFiles(in: directory)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].hasSuffix("id_ed25519"))
    }
}
