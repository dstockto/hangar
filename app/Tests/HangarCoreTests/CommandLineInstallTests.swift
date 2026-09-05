import XCTest
@testable import HangarCore

/// /usr/local/bin is the line every README reaches for and it is root-owned on a
/// stock Mac, so the first install attempt used to be a sudo prompt for something
/// that did not need one.
final class CommandLineInstallTests: XCTestCase {

    private let localBin = NSString(string: "~/.local/bin").expandingTildeInPath
    private let homeBin = NSString(string: "~/bin").expandingTildeInPath

    func testItPrefersADirectoryTheUserAlreadyOwns() {
        let destination = CommandLineInstall.destination(
            onPath: ["/usr/bin", "/usr/local/bin", localBin, "/opt/homebrew/bin"],
            writable: [localBin, "/opt/homebrew/bin", "/usr/local/bin"])
        XCTAssertEqual(destination, localBin)
    }

    func testItFallsDownThePreferenceOrder() {
        XCTAssertEqual(
            CommandLineInstall.destination(onPath: ["/opt/homebrew/bin", homeBin],
                                           writable: ["/opt/homebrew/bin", homeBin]),
            "/opt/homebrew/bin")
        XCTAssertEqual(
            CommandLineInstall.destination(onPath: ["/usr/local/bin", homeBin],
                                           writable: ["/usr/local/bin", homeBin]),
            homeBin, "the user's own beats the one that usually needs sudo")
    }

    /// A directory that is writable but not on PATH would install a command the
    /// shell never finds, which looks exactly like an install that failed.
    func testADirectoryOffThePathIsNotADestination() {
        XCTAssertNil(CommandLineInstall.destination(onPath: ["/usr/bin"],
                                                    writable: [localBin]))
    }

    func testADirectoryOnThePathThatCannotBeWrittenIsNotADestination() {
        XCTAssertNil(CommandLineInstall.destination(onPath: ["/usr/local/bin"],
                                                    writable: []))
    }

    /// PATH entries are whatever a shell profile accumulated over the years.
    func testATrailingSlashIsStillTheSameDirectory() {
        XCTAssertEqual(
            CommandLineInstall.destination(onPath: ["/opt/homebrew/bin/"],
                                           writable: ["/opt/homebrew/bin"]),
            "/opt/homebrew/bin")
    }

    func testPathIsSplitOnColonsWithTheEmptyEntriesDropped() {
        XCTAssertEqual(CommandLineInstall.searchPath("/usr/bin::/bin:"),
                       ["/usr/bin", "/bin"])
        XCTAssertEqual(CommandLineInstall.searchPath(nil), [])
    }

    /// An app can live under a path with a space in it, and the line is pasted
    /// into a shell.
    func testTheManualCommandQuotesBothPaths() {
        let command = CommandLineInstall.manualCommand(
            tool: "/Applications/My Apps/Hangar.app/Contents/Helpers/hangar")
        XCTAssertTrue(command.hasPrefix("sudo ln -sfn "), command)
        XCTAssertTrue(command.contains("'/Applications/My Apps/Hangar.app"), command)
        XCTAssertTrue(command.hasSuffix("'/usr/local/bin/hangar'"), command)
    }

    // MARK: - What the check says about each state

    func testAnInstalledCommandIsReportedRatherThanOffered() {
        let check = Preflight.commandLineCheck(.installed(link: "/x/hangar"),
                                               toolPath: "/tool")
        XCTAssertEqual(check.level, .ok)
        XCTAssertNil(check.remedy)
    }

    func testAMissingCommandOffersToInstallItself() {
        let check = Preflight.commandLineCheck(.absent(destination: "/x/bin"),
                                               toolPath: "/tool")
        XCTAssertEqual(check.level, .warning)
        XCTAssertEqual(check.remedy, .installCommandLine)
        XCTAssertTrue(check.detail.contains("/x/bin"), check.detail)
    }

    /// Nowhere writable is not a button, it is a line the user runs.
    func testNowhereWritableOffersTheCommandInstead() {
        let check = Preflight.commandLineCheck(.absent(destination: nil),
                                               toolPath: "/tool")
        XCTAssertEqual(check.remedy,
                       .copyCommand(CommandLineInstall.manualCommand(tool: "/tool")))
    }

    /// Somebody else's `hangar` is far more likely to be deliberate than stale.
    func testSomebodyElsesCommandIsLeftAloneAndSaidSo() {
        let check = Preflight.commandLineCheck(.claimed(link: "/x/hangar"),
                                               toolPath: "/tool")
        XCTAssertEqual(check.level, .warning)
        XCTAssertNil(check.remedy, "Hangar does not overwrite what it did not write")
        XCTAssertTrue(check.detail.contains("left alone"), check.detail)
    }

    func testALinkToADeletedCopyCanBeRepointed() {
        let check = Preflight.commandLineCheck(.broken(link: "/x/hangar"),
                                               toolPath: "/tool")
        XCTAssertEqual(check.remedy, .installCommandLine)
    }

    func testABuildWithNoToolSaysSoRatherThanOfferingAnInstall() {
        let check = Preflight.commandLineCheck(.absent(destination: "/x/bin"),
                                               toolPath: nil)
        XCTAssertEqual(check.level, .warning)
        XCTAssertNil(check.remedy)
    }
}
