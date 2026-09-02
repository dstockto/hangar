import XCTest
@testable import HangarCore

/// Deleting an app leaves its support files behind, so a reinstall used to serve
/// the old cache and skip setup, which looks like the delete did not take.
final class InstallStateTests: TemporaryDirectoryTestCase {

    private var statePath: String { path(".install") }

    func testAFirstRunHasNothingToCompareAgainst() {
        let launch = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                           statePath: statePath)
        XCTAssertEqual(launch, .first)
        XCTAssertTrue(InstallState.shouldStartFresh(launch))
    }

    func testTheSameBundleTwiceIsUnchanged() {
        _ = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                  statePath: statePath)
        let second = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                           statePath: statePath)
        XCTAssertEqual(second, .unchanged)
        XCTAssertFalse(InstallState.shouldStartFresh(second),
                       "an ordinary relaunch must not reopen setup")
    }

    func testAHigherVersionIsAnUpgradeAndKeepsEverything() {
        _ = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                  statePath: statePath)
        // An in-place update writes a new bundle, so the timestamp moves too.
        let launch = InstallState.classify(version: "0.0.4", bundleCreated: 9000,
                                           statePath: statePath)
        XCTAssertEqual(launch, .upgraded(from: "0.0.3"))
        XCTAssertFalse(InstallState.shouldStartFresh(launch),
                       "updating must not throw the user back into setup")
    }

    func testTheSameVersionFromANewBundleIsAReinstall() {
        // Drag to Trash, install the DMG again: same version, new bundle.
        _ = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                  statePath: statePath)
        let launch = InstallState.classify(version: "0.0.3", bundleCreated: 9000,
                                           statePath: statePath)
        XCTAssertEqual(launch, .reinstalled(version: "0.0.3"))
        XCTAssertTrue(InstallState.shouldStartFresh(launch))
    }

    func testAReinstallOfAnOlderVersionAlsoCountsAsAReinstall() {
        _ = InstallState.classify(version: "0.0.4", bundleCreated: 1000,
                                  statePath: statePath)
        let launch = InstallState.classify(version: "0.0.3", bundleCreated: 9000,
                                           statePath: statePath)
        XCTAssertEqual(launch, .reinstalled(version: "0.0.3"))
    }

    func testASecondOfTimestampJitterIsNotAReinstall() {
        // A filesystem copy can round the creation date; a whole app reinstall
        // moves it by far more than a second.
        _ = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                  statePath: statePath)
        XCTAssertEqual(InstallState.classify(version: "0.0.3", bundleCreated: 1000.4,
                                             statePath: statePath),
                       .unchanged)
    }

    func testAMissingBundleDateDoesNotInventAReinstall() {
        _ = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                  statePath: statePath)
        XCTAssertEqual(InstallState.classify(version: "0.0.3", bundleCreated: nil,
                                             statePath: statePath),
                       .unchanged, "unknown is not the same as newer")
    }

    func testTheRecordIsWrittenAt0600() throws {
        _ = InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                  statePath: statePath)
        let mode = try FileManager.default
            .attributesOfItem(atPath: statePath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAnUnreadableRecordIsTreatedAsAFirstRun() throws {
        try "not json".write(toFile: statePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(InstallState.classify(version: "0.0.3", bundleCreated: 1000,
                                             statePath: statePath),
                       .first)
    }

    func testABundleOnDiskReportsACreationDate() throws {
        // The mechanism the whole thing rests on, checked against a real
        // directory rather than assumed.
        let bundle = directory.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: bundle,
                                                withIntermediateDirectories: true)
        XCTAssertNotNil(InstallState.bundleCreated(at: bundle))
    }
}
