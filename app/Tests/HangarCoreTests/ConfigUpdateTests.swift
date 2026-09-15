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

    /// The config sits beside the fleet cache and is no less private.
    func testTheFileItWritesIs0600() throws {
        let file = path("config.json")
        try HangarConfig.update(at: file) { $0.region = "us-west-2" }

        let mode = try FileManager.default
            .attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }
}
