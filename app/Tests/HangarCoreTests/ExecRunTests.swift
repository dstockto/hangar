import XCTest
@testable import HangarCore

/// What an `--exec` run does once its commands are going. The loop that signals
/// them needs a real terminal and lives in the `hangar` target; these are the
/// decisions it makes, plus the two process facts it reads.
final class ExecRunTests: XCTestCase {

    // MARK: - Endings

    func testAnEndingIsReadFromHowTheProcessFinished() {
        XCTAssertEqual(ExecRun.Ending(reason: .exit, status: 3), .exited(3))
        XCTAssertEqual(ExecRun.Ending(reason: .uncaughtSignal, status: SIGTERM),
                       .signalled(SIGTERM))
    }

    func testOnlyACleanExitSucceeds() {
        XCTAssertTrue(ExecRun.Ending.exited(0).succeeded)
        XCTAssertFalse(ExecRun.Ending.exited(1).succeeded)
        XCTAssertFalse(ExecRun.Ending.signalled(SIGTERM).succeeded)
    }

    // MARK: - What ends the run

    /// At one host at a time the command holds the terminal, so a command that
    /// died of Ctrl-C is the only sign the key was pressed.
    func testACommandKilledByCtrlCStopsTheRun() {
        XCTAssertEqual(ExecRun.interruption(.signalled(SIGINT), heldTerminal: true), SIGINT)
        XCTAssertEqual(ExecRun.interruption(.signalled(SIGQUIT), heldTerminal: true), SIGQUIT)
    }

    /// Above one at a time no command holds the terminal, so one that died of
    /// SIGINT sent it to itself. Taking that as Ctrl-C once marked the run
    /// interrupted, and the real key then did nothing while the others ran on.
    func testASigintTheTerminalNeverSentDoesNotStopTheRun() {
        XCTAssertNil(ExecRun.interruption(.signalled(SIGINT), heldTerminal: false))
        XCTAssertNil(ExecRun.interruption(.signalled(SIGQUIT), heldTerminal: false))
    }

    /// SIGTERM and SIGKILL are what the deadline sends. A host that ran out of
    /// time is a failure on that host, not a person asking to stop.
    func testTheDeadlinesOwnSignalsDoNotStopTheRun() {
        XCTAssertNil(ExecRun.interruption(.signalled(SIGTERM), heldTerminal: true))
        XCTAssertNil(ExecRun.interruption(.signalled(SIGKILL), heldTerminal: true))
    }

    /// A command that caught the interrupt and exited on its own terms is taken
    /// at its word, the way a shell takes it.
    func testAnExitCodeIsNeverReadAsAnInterrupt() {
        XCTAssertNil(ExecRun.interruption(.exited(130), heldTerminal: true))
        XCTAssertNil(ExecRun.interruption(.exited(0), heldTerminal: true))
    }

    /// The SIGPIPE itself is recorded on another queue and can land after the
    /// last write, so the failed write is what reliably says the reader left.
    func testAReaderThatWentAwayStopsTheRunAsSIGPIPE() {
        XCTAssertEqual(ExecRun.interruption(writeError: EPIPE, watchingSIGPIPE: true), SIGPIPE)
        XCTAssertEqual(ExecRun.exitCode(interruptedBy: SIGPIPE), 141)
    }

    /// Under a SIGPIPE ignored beforehand the run carried on past a dead reader,
    /// and standing in for the signal must not change that.
    func testAnIgnoredSIGPIPEStaysIgnoredWhenTheWriteFails() {
        XCTAssertNil(ExecRun.interruption(writeError: EPIPE, watchingSIGPIPE: false))
    }

    /// A full disk or a bad descriptor is not a person or a reader asking to stop.
    func testOtherWriteErrorsDoNotStopTheRun() {
        XCTAssertNil(ExecRun.interruption(writeError: ENOSPC, watchingSIGPIPE: true))
        XCTAssertNil(ExecRun.interruption(writeError: EBADF, watchingSIGPIPE: true))
    }

    func testAnInterruptedRunExitsTheWayAShellReportsIt() {
        XCTAssertEqual(ExecRun.exitCode(interruptedBy: SIGINT), 130)
        XCTAssertEqual(ExecRun.exitCode(interruptedBy: SIGTERM), 143)
        XCTAssertEqual(ExecRun.exitCode(interruptedBy: SIGHUP), 129)
    }

    // MARK: - Words

    /// "exit 2" for a command killed by SIGINT reads as the command's own verdict.
    func testAKilledCommandSaysWhatKilledIt() {
        XCTAssertEqual(ExecRun.describe(.exited(2)), "exit 2")
        XCTAssertEqual(ExecRun.describe(.signalled(SIGINT)), "killed by SIGINT")
        XCTAssertEqual(ExecRun.describe(.signalled(SIGKILL)), "killed by SIGKILL")
        XCTAssertEqual(ExecRun.describe(.signalled(SIGUSR2)), "killed by signal \(SIGUSR2)")
    }

    /// `sh` can outlive its group's SIGTERM, report the child it lost and exit 0,
    /// and that once made a host the deadline stopped count as a success.
    func testAHostThatRanOutOfTimeFailsWhateverItExitedWith() {
        XCTAssertFalse(ExecRun.succeeded(.exited(0), timedOut: true))
        XCTAssertFalse(ExecRun.succeeded(.signalled(SIGTERM), timedOut: true))
        XCTAssertTrue(ExecRun.succeeded(.exited(0), timedOut: false))
        XCTAssertFalse(ExecRun.succeeded(.exited(1), timedOut: false))
    }

    func testAHostThatRanOutOfTimeIsNotReportedAsExitZero() {
        XCTAssertEqual(ExecRun.describe(.exited(0), timedOut: true), "timed out")
        XCTAssertEqual(ExecRun.describe(.signalled(SIGTERM), timedOut: true),
                       "killed by SIGTERM")
        XCTAssertEqual(ExecRun.describe(.exited(2), timedOut: true), "exit 2")
        XCTAssertEqual(ExecRun.describe(.exited(2), timedOut: false), "exit 2")
    }

    func testAnInterruptedRunSaysHowFarItGot() {
        XCTAssertEqual(ExecRun.interrupted(notRun: 0), "interrupted.")
        XCTAssertEqual(ExecRun.interrupted(notRun: 1), "interrupted, 1 host not run.")
        XCTAssertEqual(ExecRun.interrupted(notRun: 17), "interrupted, 17 hosts not run.")
    }

    // MARK: - A stopped process

    /// `Process.isRunning` says yes for a stopped process, which is how a command
    /// stopped by the terminal was waited on forever.
    func testAStoppedProcessIsToldApartFromARunningOne() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier

        XCTAssertFalse(ExecRun.isStopped(pid))
        kill(pid, SIGSTOP)
        XCTAssertTrue(eventually { ExecRun.isStopped(pid) })
        XCTAssertTrue(process.isRunning, "the reason this check exists")
        kill(pid, SIGCONT)
        XCTAssertTrue(eventually { !ExecRun.isStopped(pid) })
    }

    func testAProcessThatDoesNotExistIsNotStopped() {
        XCTAssertFalse(ExecRun.isStopped(99_999_999))
    }

    // MARK: - Where stdout goes

    /// A pipe's reader is in the same job and may need the terminal, as `less`
    /// does, so only a pipe keeps the terminal from the command.
    func testAPipeIsToldApartFromAFile() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { ends.forEach { close($0) } }
        XCTAssertTrue(ExecRun.isPipe(ends[0]))
        XCTAssertTrue(ExecRun.isPipe(ends[1]))

        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        XCTAssertTrue(ExecRun.isPipe(pair[0]), "a socket has a reader too")

        let path = NSTemporaryDirectory() + "hangar-isPipe-\(getpid())"
        let file = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(file, 0)
        defer { close(file); unlink(path) }
        XCTAssertFalse(ExecRun.isPipe(file), "`> out.txt` has no reader in the job")

        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        XCTAssertFalse(ExecRun.isPipe(null))
    }

    func testAClosedDescriptorIsNotAPipe() {
        XCTAssertFalse(ExecRun.isPipe(-1))
    }

    // MARK: - Watching signals

    /// SIGUSR1 and SIGUSR2 stand in for the real ones, because ignoring SIGINT
    /// in the test runner would outlive a failing test.
    func testASignalIsCollectedRatherThanActedOn() {
        let watch = SignalWatch([SIGUSR1])
        watch.start()
        defer { watch.stop() }
        XCTAssertNil(watch.received)

        kill(getpid(), SIGUSR1)
        XCTAssertTrue(eventually { watch.received == SIGUSR1 })
    }

    /// The first signal decides the exit code, so a second one does not
    /// rewrite it.
    func testTheFirstSignalIsTheOneKept() {
        let watch = SignalWatch([SIGUSR1, SIGUSR2])
        watch.start()
        defer { watch.stop() }

        kill(getpid(), SIGUSR2)
        XCTAssertTrue(eventually { watch.received == SIGUSR2 })
        kill(getpid(), SIGUSR1)
        usleep(100_000)
        XCTAssertEqual(watch.received, SIGUSR2)
    }

    func testAWatchSaysWhichSignalsItCollects() {
        let before = signal(SIGUSR2, SIG_IGN)
        defer { signal(SIGUSR2, before) }
        let watch = SignalWatch([SIGUSR1, SIGUSR2])
        XCTAssertFalse(watch.isWatching(SIGUSR1), "nothing before start")
        watch.start()
        XCTAssertTrue(watch.isWatching(SIGUSR1))
        XCTAssertFalse(watch.isWatching(SIGUSR2), "ignored beforehand, so left alone")
        XCTAssertFalse(watch.isWatching(SIGHUP), "never asked for")
        watch.stop()
        XCTAssertFalse(watch.isWatching(SIGUSR1))
    }

    /// A source fires for an ignored signal too, so watching one that `nohup`
    /// had already ignored turned the hangup it exists to survive into the end
    /// of the run.
    func testASignalIgnoredBeforehandStaysIgnored() {
        let before = signal(SIGUSR1, SIG_IGN)
        defer { signal(SIGUSR1, before) }
        let watch = SignalWatch([SIGUSR1])
        watch.start()

        kill(getpid(), SIGUSR1)
        usleep(200_000)
        XCTAssertNil(watch.received)
        watch.stop()
        XCTAssertTrue(SignalWatch.isIgnore(signal(SIGUSR1, SIG_IGN)),
                      "stop must not restore a disposition it never replaced")
    }

    private func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}
