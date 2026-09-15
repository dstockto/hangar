import XCTest
@testable import HangarCore

/// Changing one setting in a file the user also edits by hand.
///
/// `write` serializes every field, so the read-modify-write these cases stand in
/// for used to put a stale copy of the whole config over the file. Issue 9: a
/// login added by hand was ignored by Write Aliases Now and deleted outright by
/// the next toggle.
final class ConfigUpdateTests: TemporaryDirectoryTestCase {

    func testAHandEditMadeAfterTheAppLoadedTheFileSurvives() throws {
        let file = path("config.json")
        try HangarConfig.write(HangarConfig.standard(), to: file)

        // The app reads the file once, at launch, and holds it.
        let heldInMemory = try HangarConfig.read(from: file)
        XCTAssertNil(heldInMemory.ssh?.user, "nothing ships a login")

        // The user adds one by hand, which is what the generated ssh file tells
        // them to do.
        var byHand = try HangarConfig.read(from: file)
        byHand.ssh?.user = "rocky"
        try HangarConfig.write(byHand, to: file)

        // The app now writes an unrelated setting. It must not do so from the
        // copy it has been holding since launch.
        let updated = try HangarConfig.update(at: file) { $0.launchAtLogin = true }

        XCTAssertEqual(updated.launchAtLogin, true, "the toggle landed")
        XCTAssertEqual(updated.ssh?.user, "rocky", "and did not cost the hand edit")
        XCTAssertEqual(try HangarConfig.read(from: file).ssh?.user, "rocky",
                       "on disk, not only in the value returned")
    }

    func testEachUpdateSeesTheOneBeforeIt() throws {
        let file = path("config.json")
        try HangarConfig.write(HangarConfig.standard(), to: file)

        try HangarConfig.update(at: file) { $0.terminal = "ghostty" }
        try HangarConfig.update(at: file) { $0.updateChannel = "beta" }

        let result = try HangarConfig.read(from: file)
        XCTAssertEqual(result.terminal, "ghostty", "the first change is still there")
        XCTAssertEqual(result.updateChannel, "beta")
    }

    /// A file that does not parse is someone mid-edit. `load()` already promises
    /// a typo never costs the user their settings, and this is the same promise
    /// on the writing side.
    func testAMalformedConfigIsRefusedRatherThanOverwritten() throws {
        let file = path("config.json")
        let halfTyped = #"{"ssh": {"user": "rocky",}"#
        try halfTyped.write(toFile: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HangarConfig.update(at: file) { $0.launchAtLogin = true })
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), halfTyped,
                       "the file is exactly as the user left it")
    }

    func testAnAbsentFileIsCreatedWithTheChangeApplied() throws {
        let file = path("config.json")
        let created = try HangarConfig.update(at: file) { $0.region = "eu-west-1" }

        XCTAssertEqual(created.region, "eu-west-1")
        XCTAssertEqual(created.terminal, HangarConfig.standard().terminal,
                       "the rest is the standard config, not an empty one")
        XCTAssertEqual(try HangarConfig.read(from: file).region, "eu-west-1")
    }

    /// `update` leans on `load` for the absent case rather than answering it a
    /// second time, and `load` taking a path is what makes the starter file it
    /// writes provable against somewhere other than the real ~/.hangar.
    func testLoadWritesTheStarterFileWhenThereIsNone() throws {
        let file = path("config.json")
        let loaded = try HangarConfig.load(from: file)

        XCTAssertEqual(loaded.terminal, HangarConfig.standard().terminal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file),
                      "the starter file is written, not only returned")
        XCTAssertEqual(try HangarConfig.read(from: file).tags, .standard,
                       "and it ships the tag mapping so it can be edited")
    }

    /// The probe that learns an ssh login runs long enough for the user to set
    /// one by hand while it goes, and theirs is the answer. This is issue 9's own
    /// bug class, so it is pinned rather than left to the AppKit layer.
    func testALoginSetByHandOutranksOneTheProbeLearned() throws {
        let file = path("config.json")
        try HangarConfig.write(HangarConfig.standard(), to: file)

        var byHand = try HangarConfig.read(from: file)
        byHand.ssh?.user = "rocky"
        try HangarConfig.write(byHand, to: file)

        var applied = true
        let updated = try HangarConfig.update(at: file) {
            applied = $0.setLoginIfUnset("ec2-user")
        }

        XCTAssertFalse(applied, "it reports that it recorded nothing")
        XCTAssertEqual(updated.ssh?.user, "rocky")
        XCTAssertEqual(try HangarConfig.read(from: file).ssh?.user, "rocky",
                       "the hand edit is still on disk")
    }

    func testTheLearnedLoginIsRecordedWhenNothingHasChosenOne() throws {
        let file = path("config.json")
        try HangarConfig.write(HangarConfig.standard(), to: file)

        var applied = false
        try HangarConfig.update(at: file) { applied = $0.setLoginIfUnset("ec2-user") }

        XCTAssertTrue(applied)
        XCTAssertEqual(try HangarConfig.read(from: file).ssh?.user, "ec2-user")
    }

    /// Hangar ships no login, so the empty spelling has to count as unset or the
    /// probe could never record anything.
    func testAnEmptyLoginCountsAsUnset() {
        var config = HangarConfig.standard()
        config.ssh?.user = ""
        XCTAssertTrue(config.setLoginIfUnset("ec2-user"))
        XCTAssertEqual(config.ssh?.user, "ec2-user")
    }

    /// The one answer to whether a key has been chosen, which is what the
    /// unprompted adoption at launch is allowed to act on.
    func testPinsAKeyCountsBothAnAgentAndAFile() {
        var config = HangarConfig.standard()
        XCTAssertFalse(config.pinsAKey, "a fresh config has no opinion about keys")

        config.ssh?.identityFile = "~/.hangar/keys/k.pub"
        XCTAssertTrue(config.pinsAKey)

        config.ssh?.identityFile = nil
        config.ssh?.identityAgent = "/tmp/agent.sock"
        XCTAssertTrue(config.pinsAKey, "an agent socket is a preference too")
    }

    /// The config sits beside the fleet cache and is no less private.
    func testTheFileItWritesIs0600() throws {
        let file = path("config.json")
        try HangarConfig.update(at: file) { $0.region = "us-west-2" }

        let mode = try FileManager.default
            .attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }
}
