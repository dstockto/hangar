import AppKit
import HangarCore

/// Moving the running app out of the way. A process cannot delete its own bundle
/// while it is running, so a detached helper waits for this one to exit first.
/// The same shape as the update swap helper, and for the same reason.
@MainActor
enum Uninstaller {
    enum StageResult: Sendable {
        /// Staged. Calling remove() hands off to a helper that waits for this
        /// process to exit and then moves the bundle to the Trash.
        case ready(remove: @Sendable () -> Void)
        case failed(String)
    }

    /// Writes the helper and returns it staged, or a message explaining why the
    /// app could not be moved. Nothing is deleted: the bundle goes to the Trash,
    /// so an uninstall someone regrets is one Put Back away.
    static func stageBundleRemoval(of bundle: URL = Bundle.main.bundleURL) -> StageResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("hangar-uninstall-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not prepare the uninstall helper: "
                           + error.localizedDescription)
        }

        // mv rather than asking Finder to delete: controlling Finder needs
        // Automation consent, and the prompt would arrive after Hangar has quit.
        let script = work.appendingPathComponent("uninstall.sh")
        let body = """
        #!/bin/bash
        PID=$1; TARGET=$2; WORK=$3
        for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        NAME=$(basename "$TARGET")
        DEST="$HOME/.Trash/$NAME"
        if [ -e "$DEST" ]; then
            DEST="$HOME/.Trash/$(basename "$NAME" .app) $(date +%Y-%m-%d-%H%M%S).app"
        fi
        if ! mv "$TARGET" "$DEST"; then
            osascript -e 'display notification "Hangar removed its files but could not \
        move itself to the Trash. Drag it there from your Applications folder." \
        with title "Hangar"' 2>/dev/null
        fi
        rm -rf "$WORK"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return .failed("Could not write the uninstall helper: "
                           + error.localizedDescription)
        }

        let target = bundle.path
        return .ready(remove: {
            // nohup plus & detaches the helper into its own lineage, so quitting
            // this app does not take the helper down with it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c",
                "nohup /bin/bash \(Shell.quoted(script.path)) \(getpid()) "
                + "\(Shell.quoted(target)) \(Shell.quoted(work.path)) >/dev/null 2>&1 &"]
            try? process.run()
            process.waitUntilExit()
        })
    }
}
