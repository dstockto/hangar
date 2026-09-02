import XCTest
@testable import HangarCore

/// The first uninstall removed the bundle it was running from and nothing else,
/// so a second copy survived, kept its login item, and rebuilt ~/.hangar on its
/// next launch. These pin the decision about which copies go.
final class InstalledCopiesTests: XCTestCase {
    private let always: (String) -> Bool = { _ in true }
    private let roots = ["/Applications", "/Users/x/Applications"]

    func testTheRunningCopyComesFirst() {
        let list = InstalledCopies.toRemove(
            running: "/Users/x/Applications/Hangar.app",
            found: ["/Applications/Hangar.app"],
            installRoots: roots, isRemovable: always)
        XCTAssertEqual(list, ["/Users/x/Applications/Hangar.app", "/Applications/Hangar.app"])
    }

    func testLaunchServicesDuplicatesCollapse() {
        let list = InstalledCopies.toRemove(
            running: "/Applications/Hangar.app",
            found: ["/Applications/Hangar.app", "/Applications/hangar.app",
                    "/Applications/./Hangar.app"],
            installRoots: roots, isRemovable: always)
        XCTAssertEqual(list, ["/Applications/Hangar.app"])
    }

    func testACopyThatCannotBeMovedIsReportedRatherThanAttempted() {
        let readOnly = "/Volumes/Hangar 0.0.6/Hangar.app"
        let removable: (String) -> Bool = { $0 != readOnly }
        let list = InstalledCopies.toRemove(running: readOnly,
                                            found: ["/Applications/Hangar.app"],
                                            installRoots: roots, isRemovable: removable)
        XCTAssertEqual(list, ["/Applications/Hangar.app"])
        XCTAssertEqual(InstalledCopies.leftInPlace(running: readOnly,
                                                   found: ["/Applications/Hangar.app"],
                                                   installRoots: roots,
                                                   isRemovable: removable),
                       [readOnly])
    }

    func testEveryFoundCopyIsAccountedForSomewhere() {
        // Nothing may be dropped on the floor: a copy is either removed or named.
        let found = ["/Applications/Hangar.app", "/Volumes/DMG/Hangar.app",
                     "/Users/x/Applications/Hangar.app"]
        let removable: (String) -> Bool = { !$0.hasPrefix("/Volumes/") }
        let running = "/Applications/Hangar.app"
        let gone = InstalledCopies.toRemove(running: running, found: found,
                                            installRoots: roots, isRemovable: removable)
        let kept = InstalledCopies.leftInPlace(running: running, found: found,
                                               installRoots: roots, isRemovable: removable)
        XCTAssertEqual(Set(gone).union(kept).count, 3)
        XCTAssertTrue(Set(gone).isDisjoint(with: Set(kept)))
    }

    func testABuildInASourceTreeIsNotAnInstalledCopy() {
        // Launch Services reports it because it has been launched once. Trashing
        // someone's build output is not what uninstall means, so it is named and
        // left where it is.
        let dist = "/Users/x/code/hangar/dist/Hangar.app"
        let running = "/Applications/Hangar.app"
        XCTAssertEqual(InstalledCopies.toRemove(running: running, found: [dist],
                                                installRoots: roots, isRemovable: always),
                       [running])
        XCTAssertEqual(InstalledCopies.leftInPlace(running: running, found: [dist],
                                                   installRoots: roots, isRemovable: always),
                       [dist])
    }

    func testTheRunningCopyGoesEvenFromAnUnusualPlace() {
        let odd = "/Users/x/code/hangar/dist/Hangar.app"
        XCTAssertEqual(InstalledCopies.toRemove(running: odd, found: [],
                                                installRoots: roots, isRemovable: always),
                       [odd], "the user uninstalled from this one")
    }

    func testDescribeAbbreviatesOnlyTheHomeDirectory() {
        let text = InstalledCopies.describe(
            ["/Users/x/Applications/Hangar.app", "/Applications/Hangar.app"],
            home: "/Users/x")
        XCTAssertEqual(text, "~/Applications/Hangar.app\n/Applications/Hangar.app")
    }
}
