import Foundation
import os

/// What happens to an `hangar --exec` run once its commands are going: how each
/// one ended, whether that ends the run, and what the run says when it stops.
///
/// The loop that starts and signals the commands is in the `hangar` target,
/// which the suite cannot reach. Every decision it makes is here instead.
public enum ExecRun {

    /// How a command finished, as `Process` reports it.
    public enum Ending: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)

        public init(reason: Process.TerminationReason, status: Int32) {
            self = reason == .uncaughtSignal ? .signalled(status) : .exited(status)
        }

        public var succeeded: Bool { self == .exited(0) }
    }

    /// The signal in this ending that means the person wants the whole run to
    /// stop, if there is one.
    ///
    /// At one host at a time the command owns the terminal, so Ctrl-C reaches it
    /// and not `hangar`, and a command that died of it is the only sign the key
    /// was pressed. Someone stopping host three of twenty wants to stop, not to
    /// move on to host four. A command that caught the signal and exited on its
    /// own terms is taken at its word, the way a shell takes it.
    public static func interruption(_ ending: Ending) -> Int32? {
        guard case .signalled(let signal) = ending,
              signal == SIGINT || signal == SIGQUIT else { return nil }
        return signal
    }

    /// The code a shell reports for a process a signal ended, so 130 for Ctrl-C.
    public static func exitCode(interruptedBy signal: Int32) -> Int32 {
        128 + signal
    }

    /// An ending in words, for the line that names a host that did not succeed.
    /// "exit 2" for a command killed by SIGINT would read as the command's own
    /// verdict, and the deadline and Ctrl-C both kill things now.
    public static func describe(_ ending: Ending) -> String {
        switch ending {
        case .exited(let status):    return "exit \(status)"
        case .signalled(let signal): return "killed by \(name(of: signal))"
        }
    }

    static func name(of signal: Int32) -> String {
        switch signal {
        case SIGHUP:  return "SIGHUP"
        case SIGINT:  return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGKILL: return "SIGKILL"
        case SIGPIPE: return "SIGPIPE"
        case SIGTERM: return "SIGTERM"
        default:      return "signal \(signal)"
        }
    }

    /// The line an interrupted run ends on. It names what was never started,
    /// because a run that stops partway has to say how far it got.
    public static func interrupted(notRun: Int) -> String {
        switch notRun {
        case 0:  return "interrupted."
        case 1:  return "interrupted, 1 host not run."
        default: return "interrupted, \(notRun) hosts not run."
        }
    }

    /// Whether a process is stopped. `Process.isRunning` says yes for a stopped
    /// process, so a command stopped by the terminal looked like one still working.
    public static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0,
              size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) == SSTOP
    }
}

/// Signals that would end this process, collected so the caller can act on them.
///
/// Each one is ignored first, so its default action does not end the process
/// before anything has seen it, and a dispatch source records the first to
/// arrive. The source runs outside signal-handler context, where taking a lock
/// is allowed. Children are unaffected: `Process` resets every disposition and
/// the signal mask when it spawns.
///
/// A signal that was already ignored is left alone and never reported. A source
/// fires for an ignored signal too, so without that check `nohup` stopped
/// protecting anything.
public final class SignalWatch {
    private let signals: [Int32]
    private let queue = DispatchQueue(label: "hangar.signal-watch")
    private let first = OSAllocatedUnfairLock<Int32?>(initialState: nil)
    private var sources: [DispatchSourceSignal] = []
    private var previous: [Int32: sig_t?] = [:]

    public init(_ signals: [Int32]) {
        self.signals = signals
    }

    public func start() {
        guard sources.isEmpty else { return }
        for signal in signals {
            let before = Darwin.signal(signal, SIG_IGN)
            if Self.isIgnore(before) { continue }
            previous[signal] = before
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { [first] in
                first.withLock { $0 = $0 ?? signal }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// The first signal that arrived since `start`, if any did.
    public var received: Int32? {
        first.withLock { $0 }
    }

    /// Function pointers are not comparable, so this compares the addresses.
    static func isIgnore(_ handler: sig_t?) -> Bool {
        unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    /// Stops watching and puts each signal's previous disposition back.
    public func stop() {
        for source in sources { source.cancel() }
        sources = []
        for (signal, handler) in previous { _ = Darwin.signal(signal, handler ?? SIG_DFL) }
        previous = [:]
    }
}
