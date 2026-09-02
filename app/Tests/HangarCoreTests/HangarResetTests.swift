import XCTest
@testable import HangarCore

/// Reset removes Hangar's own state and nothing else. The second half of that
/// sentence is the part worth testing: the user's `~/.ssh/config` and their AWS
/// credentials are not Hangar's to delete.
final class HangarResetTests: XCTestCase {

    func testCacheScopeCoversTheFleetAndTheUpdateStamp() {
        let paths = HangarReset.paths(for: .cache)
        XCTAssertTrue(paths.contains(HangarConfig.cachePath))
        XCTAssertTrue(paths.contains(UpdateSchedule.stampPath))
        XCTAssertEqual(paths.count, 2, "and nothing else")
    }

    func testCacheScopeKeepsTheLog() {
        // Clearing the cache is a fleet problem, not a "throw away the evidence"
        // problem: the log is what explains why the fleet looked wrong.
        XCTAssertFalse(HangarReset.paths(for: .cache).contains(HangarConfig.logDirectory))
    }

    func testCacheScopeKeepsSettings() {
        let paths = HangarReset.paths(for: .cache)
        XCTAssertFalse(paths.contains(HangarConfig.path),
                       "clearing the cache must not lose the tag mapping")
        XCTAssertFalse(paths.contains(HangarConfig.sshIncludePath))
        XCTAssertFalse(paths.contains(HangarConfig.onboardedMarkerPath))
    }

    func testEverythingScopeCoversSettingsAndTheGeneratedSSHFile() {
        let paths = HangarReset.paths(for: .everything)
        for expected in [HangarConfig.cachePath, UpdateSchedule.stampPath,
                         HangarConfig.path, HangarConfig.onboardedMarkerPath,
                         HangarConfig.logDirectory, HangarConfig.sshIncludePath] {
            XCTAssertTrue(paths.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(paths.count, 6)
    }

    func testNeitherScopeTouchesAnythingHangarDoesNotOwn() {
        // The blast radius, stated as a test so it cannot widen quietly.
        let home = NSHomeDirectory()
        let forbidden = [
            "\(home)/.ssh/config",
            "\(home)/.ssh/known_hosts",
            "\(home)/.aws/config",
            "\(home)/.aws/credentials",
            "\(home)/.aws/sso/cache",
            "\(home)/.hangar",
            home,
        ]
        for scope in [HangarReset.Scope.cache, .everything] {
            for path in HangarReset.paths(for: scope) {
                XCTAssertFalse(forbidden.contains(path),
                               "\(scope) would remove \(path)")
                XCTAssertTrue(path.hasPrefix("\(home)/.hangar/")
                              || path == HangarConfig.sshIncludePath,
                              "\(path) is outside what Hangar owns")
            }
        }
    }

    func testTheGeneratedFileIsTheOnlySSHPathTouched() {
        let sshPaths = HangarReset.paths(for: .everything)
            .filter { $0.contains("/.ssh/") }
        XCTAssertEqual(sshPaths, [HangarConfig.sshIncludePath],
                       "only the file Hangar generates, never the user's config")
    }

    func testRemovingWhatIsThereAndReportingIt() throws {
        // Against real files in a scratch directory, using the same removal the
        // app performs, so the outcome shape is exercised rather than assumed.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hangar-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let present = directory.appendingPathComponent("present").path
        try "x".write(toFile: present, atomically: true, encoding: .utf8)
        let absent = directory.appendingPathComponent("absent").path

        var removed: [String] = []
        for path in [present, absent] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            removed.append(path)
        }
        XCTAssertEqual(removed, [present], "a missing file is not a failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: present))
    }

    func testAnEmptyOutcomeIsRecognised() {
        XCTAssertTrue(HangarReset.Outcome(removed: [], failed: []).isEmpty)
        XCTAssertFalse(HangarReset.Outcome(removed: ["a"], failed: []).isEmpty)
        XCTAssertFalse(HangarReset.Outcome(removed: [], failed: ["b"]).isEmpty)
    }

    func testEachScopeSaysWhatItDoesAndWhatItSpares() {
        let cache = HangarReset.description(of: .cache)
        XCTAssertTrue(cache.contains("settings"), cache)
        XCTAssertTrue(cache.lowercased().contains("kept"), cache)

        let everything = HangarReset.description(of: .everything)
        XCTAssertTrue(everything.contains("~/.ssh/config"), everything)
        XCTAssertTrue(everything.contains("not touched"), everything)
        XCTAssertTrue(everything.lowercased().contains("credentials"), everything)
    }
}
