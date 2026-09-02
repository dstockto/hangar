import XCTest
@testable import HangarCore

/// An uninstall has the widest blast radius in the app, and it is the only
/// operation that edits the user's own ~/.ssh/config. Both halves are pinned
/// here: what it removes, and what it leaves exactly as it found it.
final class HangarUninstallTests: XCTestCase {

    func testCoversTheSupportDirectoryAndTheGeneratedSSHFile() {
        XCTAssertEqual(HangarUninstall.paths,
                       [HangarConfig.home, HangarConfig.sshIncludePath])
    }

    func testRemovesTheDirectoryRatherThanTheFilesInIt() {
        // An empty ~/.hangar left behind is what made a delete and reinstall
        // look like the delete had not taken.
        XCTAssertTrue(HangarUninstall.paths.contains(HangarConfig.home))
        for path in HangarReset.paths(for: .everything)
        where path.hasPrefix("\(HangarConfig.home)/") {
            XCTAssertFalse(HangarUninstall.paths.contains(path),
                           "\(path) is covered by removing the directory")
        }
    }

    func testTouchesNothingHangarDoesNotOwn() {
        let home = NSHomeDirectory()
        for path in HangarUninstall.paths {
            XCTAssertTrue(path == HangarConfig.home || path == HangarConfig.sshIncludePath,
                          "\(path) is outside what Hangar owns")
            XCTAssertNotEqual(path, home)
            XCTAssertNotEqual(path, "\(home)/.ssh")
            XCTAssertNotEqual(path, "\(home)/.ssh/config")
            XCTAssertNotEqual(path, "\(home)/.aws")
        }
    }

    func testDescriptionNamesTheIncludeLineAndTheTrash() {
        let text = HangarUninstall.description
        XCTAssertTrue(text.contains("~/.ssh/config"))
        XCTAssertTrue(text.contains("Trash"))
        XCTAssertTrue(text.contains("AWS credentials"))
        XCTAssertFalse(text.contains("\u{2014}"), "no em dashes in user-facing copy")
    }

    // MARK: - Taking the Include line back out

    private func temporaryConfig(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "/hangar-uninstall-\(UUID().uuidString)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".hangar-backup")
        }
        return path
    }

    func testRemoveIncludeLineLeavesTheRestOfTheFileAlone() throws {
        let path = try temporaryConfig("""
        Include ~/.ssh/config.d/hangar

        Host bastion
          HostName 10.0.0.1
          User deploy
        """)
        XCTAssertTrue(try SSHConfigWriter.removeIncludeLine(from: path))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text, """
        Host bastion
          HostName 10.0.0.1
          User deploy
        """)
    }

    func testRemoveIncludeLineIsANoOpWhenTheLineIsAbsent() throws {
        let original = "Host bastion\n  HostName 10.0.0.1\n"
        let path = try temporaryConfig(original)
        XCTAssertFalse(try SSHConfigWriter.removeIncludeLine(from: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testRemoveIncludeLineKeepsAnUnrelatedInclude() throws {
        let path = try temporaryConfig("""
        Include ~/.ssh/config.d/work
        Include ~/.ssh/config.d/hangar
        Host bastion
        """)
        XCTAssertTrue(try SSHConfigWriter.removeIncludeLine(from: path))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("config.d/work"))
        XCTAssertFalse(text.contains("config.d/hangar"))
    }

    func testRemoveIncludeLineBacksUpFirst() throws {
        let original = SSHConfigWriter.includeLine + "\n\nHost bastion\n"
        let path = try temporaryConfig(original)
        XCTAssertTrue(try SSHConfigWriter.removeIncludeLine(from: path))
        XCTAssertEqual(try String(contentsOfFile: path + ".hangar-backup", encoding: .utf8),
                       original)
    }

    func testAddThenRemoveIsRoundTrip() throws {
        let original = "Host bastion\n  HostName 10.0.0.1\n"
        let path = try temporaryConfig(original)
        try SSHConfigWriter.addIncludeLine(to: path)
        XCTAssertTrue(SSHConfigWriter.includeLinePresent(in: path))
        XCTAssertTrue(try SSHConfigWriter.removeIncludeLine(from: path))
        XCTAssertFalse(SSHConfigWriter.includeLinePresent(in: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testTheEditedFileStaysPrivate() throws {
        let path = try temporaryConfig(SSHConfigWriter.includeLine + "\n\nHost bastion\n")
        XCTAssertTrue(try SSHConfigWriter.removeIncludeLine(from: path))
        let mode = try FileManager.default
            .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }
}
