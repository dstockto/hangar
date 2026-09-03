import Foundation

/// Runs an external process with a deadline it cannot outlive.
///
/// Every process Hangar starts is somebody else's code: a credential helper, an
/// ssh agent behind a locked vault, ssh itself. `readDataToEndOfFile` blocks
/// until the write end closes, which is exactly what a hung helper never does,
/// so the read happens after the wait and the wait has a kill behind it.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public var out: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }
        public var err: String {
            String(data: stderr, encoding: .utf8) ?? ""
        }
    }

    /// How long a process gets before it is terminated, and then killed.
    public static let defaultTimeout: TimeInterval = 15

    /// Output is read after the process ends, so anything larger than the pipe
    /// buffer would deadlock. Every caller here reads well under 64KB; a caller
    /// that will not should stream instead of using this.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw HangarError.timedOut(
                "\((executable as NSString).lastPathComponent) did not finish within "
                + "\(Int(timeout)) seconds")
        }

        return Result(status: process.terminationStatus,
                      stdout: out.fileHandleForReading.readDataToEndOfFile(),
                      stderr: err.fileHandleForReading.readDataToEndOfFile())
    }

    /// The user's own command, run through a shell because that is how they wrote
    /// it. Same deadline; a shell that waits forever is still a process that
    /// waits forever.
    public static func shell(_ command: String,
                             timeout: TimeInterval = defaultTimeout) throws -> Result {
        try run("/bin/sh", ["-c", command], timeout: timeout)
    }
}
