import Foundation

/// The controlling terminal, handed to one command at a time the way a shell
/// hands it to a job.
///
/// Opened as `/dev/tty` rather than read off stdin, because ssh asks for a
/// password on `/dev/tty` even when stdin is a pipe. It is only handed over while
/// this process's group is the terminal's foreground group, which is the only
/// time it is ours to give away.
///
/// While it is open this process ignores SIGTTOU. Taking the terminal back is done
/// from a background group, and so is any line written while a command holds it,
/// and the kernel stops a process for either otherwise. `close` puts the previous
/// disposition back, so the rest of the process is not left ignoring it.
final class ControllingTerminal {
    private let descriptor: Int32
    private let previousTTOU: sig_t?
    /// The command the terminal is handed to, while it is handed to one.
    private(set) var holder: pid_t?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
        previousTTOU = signal(SIGTTOU, SIG_IGN)
    }

    /// The terminal this process was started from, or nil when it has none.
    static func open() -> ControllingTerminal? {
        let descriptor = Darwin.open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        return descriptor >= 0 ? ControllingTerminal(descriptor: descriptor) : nil
    }

    /// Hands the terminal to a command just started, if it is ours to give.
    ///
    /// The command may have touched the terminal before it was handed over, and
    /// been stopped for it. SIGCONT does nothing to one that was not.
    func give(to pid: pid_t) {
        guard handOver(to: pid) else { return }
        killpg(pid, SIGCONT)
    }

    /// Takes the terminal back if `pid` holds it, and says whether it did. That is
    /// also whether Ctrl-C could have reached that command rather than this one.
    @discardableResult
    func takeBack(from pid: pid_t) -> Bool {
        guard holder == pid else { return false }
        _ = tcsetpgrp(descriptor, getpgrp())
        holder = nil
        return true
    }

    /// Ctrl-Z stopped the command's group, which holds the terminal, so the shell
    /// saw nothing. This stops our job too, and gives the command the terminal
    /// back and continues it once the shell continues us in front of it.
    func suspend(_ pid: pid_t) {
        takeBack(from: pid)
        kill(0, SIGTSTP)
        handOver(to: pid)
        killpg(pid, SIGCONT)
    }

    /// Closes the terminal and puts SIGTTOU back the way `open` found it.
    func close() {
        Darwin.close(descriptor)
        _ = signal(SIGTTOU, previousTTOU ?? SIG_DFL)
    }

    @discardableResult
    private func handOver(to pid: pid_t) -> Bool {
        guard tcgetpgrp(descriptor) == getpgrp() else { return false }
        _ = tcsetpgrp(descriptor, pid)
        holder = pid
        return true
    }
}
