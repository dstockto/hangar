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
    /// app could not be moved. Nothing is deleted: the bundles go to the Trash,
    /// so an uninstall someone regrets is one Put Back away.
    static func stageBundleRemoval(of bundles: [URL]) -> StageResult {
        guard !bundles.isEmpty else { return .failed("No installed copy to remove.") }
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
        PID=$1; WORK=$2; shift 2
        for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        mkdir -p "$HOME/.Trash"
        FAILED=0
        for TARGET in "$@"; do
            [ -e "$TARGET" ] || continue
            NAME=$(basename "$TARGET")
            DEST="$HOME/.Trash/$NAME"
            if [ -e "$DEST" ]; then
                DEST="$HOME/.Trash/$(basename "$NAME" .app) $(date +%Y-%m-%d-%H%M%S).app"
            fi
            mv "$TARGET" "$DEST" || FAILED=$((FAILED + 1))
        done
        if [ "$FAILED" -gt 0 ]; then
            osascript -e "display notification \"Hangar removed its files, but $FAILED \
        copy could not be moved to the Trash. Drag it there from your Applications \
        folder.\" with title \"Hangar\"" 2>/dev/null
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

        let targets = bundles.map { Shell.quoted($0.path) }.joined(separator: " ")
        return .ready(remove: {
            // nohup plus & detaches the helper into its own lineage, so quitting
            // this app does not take the helper down with it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c",
                "nohup /bin/bash \(Shell.quoted(script.path)) \(getpid()) "
                + "\(Shell.quoted(work.path)) \(targets) >/dev/null 2>&1 &"]
            try? process.run()
            process.waitUntilExit()
        })
    }

    /// Every installed copy Launch Services knows about, plus the running one.
    /// Both are needed: Launch Services misses a copy that has never been
    /// launched, and lists copies that are no longer there.
    static func installedCopies() -> (removable: [String], stuck: [String]) {
        let running = Bundle.main.bundleURL.path
        var found: [String] = []
        if let id = Bundle.main.bundleIdentifier {
            found = NSWorkspace.shared
                .urlsForApplications(withBundleIdentifier: id)
                .map(\.path)
        }
        let isRemovable: (String) -> Bool = { path in
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else { return false }
            let parent = (path as NSString).deletingLastPathComponent
            guard fm.isWritableFile(atPath: parent) else { return false }
            // A Hangar launched from a mounted DMG cannot be moved, and saying so
            // is better than a helper that silently fails after the app has quit.
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.volumeIsReadOnlyKey])
            return values?.volumeIsReadOnly != true
        }
        return (InstalledCopies.toRemove(running: running, found: found,
                                         isRemovable: isRemovable),
                InstalledCopies.leftInPlace(running: running, found: found,
                                            isRemovable: isRemovable))
    }

    /// Quits the other running instances, so none of them writes ~/.hangar back
    /// after this one has removed it. Three seconds each, then we move on: the
    /// bundle is about to be moved out from under it anyway.
    static func quitOtherInstances() {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

}
