import XCTest
@testable import HangarCore

/// The log has two jobs: be readable by a person debugging a running Hangar, and
/// be safe to attach to a public issue without reading it line by line first.
final class LogTests: XCTestCase {

    private func temporaryLog() -> String {
        let directory = NSTemporaryDirectory() + "/hangar-log-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory + "/logs/hangar.log"
    }

    // MARK: - The line

    func testTheLineIsUTCWithSortedFields() {
        let line = Log.line(.info, .fleet, "refresh finished",
                            ["region": "us-west-2", "hosts": "223", "ms": "412"],
                            at: Date(timeIntervalSince1970: 1_788_360_069))
        XCTAssertTrue(line.hasPrefix("2026-09-02T"), line)
        XCTAssertTrue(line.hasSuffix("Z  INFO   fleet        refresh finished"
                                     + "  hosts=223 ms=412 region=us-west-2"), line)
    }

    func testValuesWithSpacesAreQuoted() {
        let line = Log.line(.error, .credentials, "refresh failed",
                            ["error": "SSO session expired", "empty": ""],
                            at: Date())
        XCTAssertTrue(line.contains("error=\"SSO session expired\""), line)
        XCTAssertTrue(line.contains("empty=\"\""), line)
    }

    func testLevelAndCategoryAreColumns() {
        let short = Log.line(.info, .app, "x", [:], at: Date())
        let long = Log.line(.error, .credentials, "x", [:], at: Date())
        func messageColumn(_ line: String) -> Int? { line.range(of: "x")?.lowerBound.utf16Offset(in: line) }
        XCTAssertEqual(messageColumn(short), messageColumn(long),
                       "a screenful has to line up")
    }

    // MARK: - The file

    func testDebugNeverReachesTheFile() {
        XCTAssertGreaterThan(Log.fileThreshold, Log.Level.debug)
    }

    func testAppendCreatesThePrivateFileAndDirectory() async {
        let path = temporaryLog()
        await LogFile(path: path).append("hello")
        let fm = FileManager.default
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "hello\n")
        let fileMode = (try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
        let dirMode = (try? fm.attributesOfItem(
            atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions]) as? NSNumber
        XCTAssertEqual(fileMode?.int16Value, 0o600)
        XCTAssertEqual(dirMode?.int16Value, 0o700)
    }

    func testAppendsAccumulateInOrder() async {
        let path = temporaryLog()
        let file = LogFile(path: path)
        for line in ["one", "two", "three"] { await file.append(line) }
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8),
                       "one\ntwo\nthree\n")
    }

    func testRotationKeepsExactlyOneGeneration() async {
        let path = temporaryLog()
        let file = LogFile(path: path, rotateAt: 200)
        for index in 0..<40 { await file.append("line \(index) " + String(repeating: "x", count: 20)) }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: path + ".1"))
        XCTAssertFalse(fm.fileExists(atPath: path + ".2"), "one generation, not a pile")
        let current = (try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber
        XCTAssertLessThanOrEqual(current?.intValue ?? .max, 400)
    }
}
