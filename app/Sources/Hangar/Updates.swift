// Update check against the GitHub releases API, on demand from the menu.
//
// Hangar already talks to AWS when you ask it to, but it still does not poll for
// updates in the background: this runs only when the user picks Check for Updates,
// or once per launch if they opt in.
import Foundation
import HangarCore

enum Updates {
    /// The public repository. Baked in so the source and the releases are reachable
    /// from the app itself, not only from wherever someone found the download.
    static let repoURL = URL(string: "https://github.com/goriparthi/hangar")!
    static let issuesURL = URL(string: "https://github.com/goriparthi/hangar/issues")!
    /// The project page, which is where a person who is not reading code goes.
    static let homepageURL = URL(string: "https://goriparthi.github.io/hangar/")!
    static let releasesURL = URL(string:
        "https://api.github.com/repos/goriparthi/hangar/releases/latest")!
    // Beta channel: the list endpoint is the only one that includes prereleases
    static let allReleasesURL = URL(string:
        "https://api.github.com/repos/goriparthi/hangar/releases?per_page=20")!

    enum Result {
        case upToDate
        case available(version: String, url: URL, dmg: URL?)
        case failed(String)
    }

    static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static var lastCheck: Date? { UpdateSchedule.lastCheck() }
    static func recordCheck() { UpdateSchedule.recordCheck() }
    static func isDue(every hours: Int) -> Bool { UpdateSchedule.isDue(every: hours) }

    static func check(currentVersion: String, channel: String = "stable",
                      completion: @escaping @Sendable (Result) -> Void) {
        let beta = channel.lowercased() == "beta"
        var request = URLRequest(url: beta ? allReleasesURL : releasesURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failed("Update check failed: \(error.localizedDescription)"))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status) else {
                // A private repo answers 404 to an unauthenticated request
                completion(.failed(status == 404 ? "No public releases found"
                                                 : "Update check failed (HTTP \(status))"))
                return
            }
            let json: [String: Any]?
            if beta {
                // Newest by version, not list order, so a stable hotfix outranks an older beta
                let list = ((try? JSONSerialization.jsonObject(with: data))
                    as? [[String: Any]] ?? [])
                    .filter { !(($0["draft"] as? Bool) ?? false) }
                json = list.max { VersionCompare.isNewer(tagVersion(of: $1),
                                                        than: tagVersion(of: $0)) }
            } else {
                json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            guard let json, let tag = json["tag_name"] as? String else {
                completion(.failed(beta ? "No releases found"
                                        : "Update check failed: unexpected response"))
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            // The DMG asset enables the in-place install; without one the page still opens
            let dmg = (json["assets"] as? [[String: Any]])?
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".dmg") }
                .flatMap(URL.init(string:))
            if VersionCompare.isNewer(latest, than: currentVersion), let page {
                completion(.available(version: latest, url: page, dmg: dmg))
            } else {
                completion(.upToDate)
            }
        }.resume()
    }

    // MARK: - In-place install

    /// Updates are only ever swapped in when they carry this exact Developer ID team,
    /// so a tampered download or a hijacked release can never replace the running app.
    static let expectedTeamID = "QX3NQYWX6F"

    enum StageResult: Sendable {
        /// Verified and staged. Calling swap() hands off to a helper that waits for
        /// this process to exit, replaces the bundle, and relaunches it.
        case ready(swap: @Sendable () -> Void)
        case failed(String)
    }

    /// Downloads the DMG, mounts it, verifies notarization and the pinned team id, and
    /// stages the new bundle next to a swap script. Nothing here touches the installed
    /// app; that happens only after the caller quits.
    static func stage(dmg: URL, replacing target: URL,
                      status: @escaping @Sendable (String) -> Void,
                      completion: @escaping @Sendable (StageResult) -> Void) {
        status("Downloading\u{2026}")
        URLSession.shared.downloadTask(with: dmg) { tmp, _, error in
            guard let tmp, error == nil else {
                completion(.failed(
                    "Download failed: \(error?.localizedDescription ?? "no data")"))
                return
            }
            // downloadTask deletes its temp file when this handler returns, so move it first
            let fm = FileManager.default
            let work = fm.temporaryDirectory
                .appendingPathComponent("hangar-update-\(UUID().uuidString)")
            let image = work.appendingPathComponent("update.dmg")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: image)
            } catch {
                completion(.failed("Could not stage the download"))
                return
            }
            status("Verifying\u{2026}")
            DispatchQueue.global(qos: .userInitiated).async {
                completion(verifyAndStage(image: image, work: work, target: target))
            }
        }.resume()
    }

    private static func verifyAndStage(image: URL, work: URL, target: URL) -> StageResult {
        let fm = FileManager.default
        func fail(_ message: String) -> StageResult {
            try? fm.removeItem(at: work)
            return .failed(message)
        }

        // -mountrandom keeps the volume out of /Volumes and away from name collisions
        let attach = run("/usr/bin/hdiutil",
                         ["attach", image.path, "-nobrowse", "-readonly",
                          "-mountrandom", fm.temporaryDirectory.path])
        guard attach.status == 0,
              let mount = attach.output.split(separator: "\n").last?
                  .split(separator: "\t").last.map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return fail("Could not open the downloaded image") }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }

        guard let app = (try? fm.contentsOfDirectory(atPath: mount))?
            .first(where: { $0.hasSuffix(".app") })
            .map({ (mount as NSString).appendingPathComponent($0) })
        else { return fail("No app inside the downloaded image") }

        // Both checks must pass: notarized by Apple, and signed by this project's team.
        // The team is enforced as a codesign requirement so the match is cryptographic;
        // grepping codesign's text output would be spoofable by the app's own filename,
        // which the DMG author chooses and which appears in that output.
        guard run("/usr/sbin/spctl", ["-a", "-t", "exec", app]).status == 0 else {
            return fail("Update rejected: not accepted by Gatekeeper")
        }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = "
            + "\"\(expectedTeamID)\""
        guard run("/usr/bin/codesign",
                  ["--verify", "--deep", "--strict", "-R=\(requirement)", app]).status == 0
        else {
            return fail("Update rejected: unexpected signing identity")
        }

        // ditto, not cp: it is the tool that preserves a bundle's symlinks, ACLs
        // and extended attributes, and the signature is checked over all of them.
        let staged = work.appendingPathComponent("staged.app")
        guard run("/usr/bin/ditto", [app, staged.path]).status == 0 else {
            return fail("Could not copy the new version")
        }

        // Verify the copy that will actually be installed, not only the one on the
        // image. Both gates, so the documentation and the code agree, and so a
        // staged copy that lost its stapled ticket is caught as well as one whose
        // signature no longer matches.
        guard run("/usr/sbin/spctl", ["-a", "-t", "exec", staged.path]).status == 0 else {
            return fail("Update rejected: the staged copy is not accepted by Gatekeeper")
        }
        guard run("/usr/bin/codesign",
                  ["--verify", "--deep", "--strict", "-R=\(requirement)", staged.path]).status == 0
        else {
            return fail("Update rejected: the staged copy failed verification")
        }

        // The helper outlives this process: it waits for exit, swaps, relaunches, cleans up
        let script = work.appendingPathComponent("swap.sh")
        // The installed app is moved aside rather than deleted, so a failed swap
        // can put it back. Deleting first means one bad mv leaves no app at all.
        let body = """
        #!/bin/bash
        PID=$1; TARGET=$2; STAGED=$3; WORK=$4
        for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        PREVIOUS="$WORK/previous.app"
        if [ -e "$TARGET" ] && ! mv "$TARGET" "$PREVIOUS"; then
            osascript -e 'display notification "Update failed; the installed app was left \
        untouched." with title "Hangar"' 2>/dev/null
            open "$TARGET"
            rm -rf "$WORK"
            exit 1
        fi
        if mv "$STAGED" "$TARGET"; then
            open "$TARGET"
        elif [ -e "$PREVIOUS" ] && mv "$PREVIOUS" "$TARGET"; then
            osascript -e 'display notification "Update failed; the previous version was \
        restored." with title "Hangar"' 2>/dev/null
            open "$TARGET"
        else
            osascript -e 'display notification "Update failed; reinstall from the release \
        page." with title "Hangar"' 2>/dev/null
        fi
        rm -rf "$WORK"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return fail("Could not write the update helper") }

        return .ready(swap: {
            // nohup plus & detaches the helper into its own lineage, so quitting this
            // app does not take the helper down with it
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c",
                "nohup /bin/bash \(quoted(script.path)) \(getpid()) \(quoted(target.path)) "
                + "\(quoted(staged.path)) \(quoted(work.path)) >/dev/null 2>&1 &"]
            try? process.run()
            process.waitUntilExit()
        })
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func tagVersion(of release: [String: Any]) -> String {
        let tag = release["tag_name"] as? String ?? "0"
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
