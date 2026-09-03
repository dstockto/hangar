import AppKit
import HangarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = FleetStore()
    private var panel: PanelController!
    private var menuBar: MenuBarController!
    private let hotKeys = HotKeyManager()
    private var refreshTimer: Timer?
    private var setup: SetupWindow?
    private var dashboard: DashboardWindow?
    private var hotkeyProblems: [String] = []
    private var primaryCombination = "\u{2318}\u{21E7}H"
    private var updateTimer: Timer?

    /// A release newer than this build, once a check has found one. The menu reads
    /// it, so the user decides when to install rather than being interrupted.
    struct Update {
        var version: String
        var page: URL
        var dmg: URL?
    }
    private(set) var availableUpdate: Update?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        menuBar = MenuBarController(
            store: store,
            onOpenPanel: { [weak self] in self?.openPanel() },
            onReloadHotkeys: { [weak self] in self?.registerHotKeys() },
            onShowSetup: { [weak self] in self?.showSetup() },
            onShowDashboard: { [weak self] in self?.showDashboard() },
            onCheckUpdates: { [weak self] in self?.checkForUpdates(quietly: false) },
            availableUpdate: { [weak self] in self?.availableUpdate },
            onInstallUpdate: { [weak self] in self?.installUpdate() },
            onReset: { [weak self] scope in self?.resetState(scope: scope) },
            onUninstall: { [weak self] in self?.uninstall() })

        registerHotKeys()
        scheduleRefresh()
        scheduleUpdateChecks()
        watchWindowsForActivationPolicy()

        // A fresh install gets the setup check once. It reads the machine and says
        // what works, which is more useful than a wizard asking questions whose
        // answers are already on disk.
        //
        // A reinstall counts as fresh. Deleting an app leaves its support files
        // behind, so without this a delete and reinstall served the old cache
        // and skipped setup, which looks like the delete did not take.
        let launch = InstallState.classify(
            version: Updates.bundleVersion,
            bundleCreated: InstallState.bundleCreated(at: Bundle.main.bundleURL))
        Log.info(.app, "launched", ["version": Updates.bundleVersion,
                                    "install": "\(launch)"])
        if case .reinstalled = launch {
            // The cache goes, so the fleet is fetched rather than remembered.
            // Settings stay: losing a tag mapping because someone reinstalled to
            // replace a damaged binary would be a nasty surprise, and Reset
            // Hangar is right there for anyone who wants nothing kept.
            HangarReset.perform(.cache)
            store.reloadAfterReset()
        }
        if InstallState.shouldStartFresh(launch) || !HangarConfig.hasOnboarded {
            showSetup()
            return
        }

        Task { @MainActor in
            await store.refresh()
            if case .failed(let message) = store.status {
                Notifier.show(title: "Hangar could not reach AWS", body: message, seconds: 5)
            }
            // After the fleet, so the ssh config it may rewrite is written once.
            if let adopted = store.adoptAgentKeyIfUnset() {
                Notifier.show(title: "Using the ssh key from your agent",
                              body: adopted, seconds: 5)
            }
            // After the key, because the probe should use it.
            if let login = await store.learnLoginIfUnset() {
                Notifier.show(title: "Learned your ssh login",
                              body: "Hosts connect as \(login). Change it in the "
                                  + "host editor, or in ~/.hangar/config.json.",
                              seconds: 5)
            }
        }
    }

    /// `.accessory` keeps Hangar out of the Dock and out of the app switcher,
    /// which is right for a menubar utility and wrong for a window that is on
    /// screen: command-tab is how someone gets back to a window they clicked
    /// away from. So the policy follows the windows, and the Dock icon comes and
    /// goes with them.
    private func watchWindowsForActivationPolicy() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                // Deferred, so a closing window is already gone from NSApp.windows
                // by the time it is counted.
                Task { @MainActor in self?.updateActivationPolicy() }
            }
        }
    }

    private func updateActivationPolicy() {
        // The floating panel is excluded: it is a nonactivating panel that
        // dismisses the moment focus moves, so it has nothing to switch back to.
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && !(window is HangarPanel)
        }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // Becoming regular without reactivating leaves the window sitting behind
        // whatever is frontmost, which is the problem this is meant to fix.
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// One window, reused, for the same reason the setup window is.
    func showDashboard() {
        if let dashboard {
            dashboard.show()
            return
        }
        let window = DashboardWindow(store: store)
        dashboard = window
        window.show()
    }

    func showSetup() {
        // One window, reused. Building a second while the first is still on screen
        // left two setup windows side by side, which is what a reset used to do.
        if let existing = setup {
            existing.show()
            return
        }
        let window = SetupWindow(
            store: store,
            hotkeyProblem: { [weak self] in self?.hotkeyProblems.first },
            hotkeyCombination: { [weak self] in self?.primaryCombination ?? "\u{2318}\u{21E7}H" },
            onOpenPanel: { [weak self] in self?.openPanel() })
        setup = window
        window.show()
    }

    /// On demand from the menu, or on the daily schedule. Either way a newer
    /// release ends in an offer to install it in place; nothing is said at all
    /// when there is nothing new and the user did not ask.
    func checkForUpdates(quietly: Bool) {
        let channel = store.config.updateChannel ?? "stable"
        if !quietly {
            Notifier.show(title: "Checking for updates\u{2026}",
                          body: "Channel: \(channel)", seconds: 1.2)
        }
        Updates.recordCheck()
        Updates.check(currentVersion: Updates.bundleVersion, channel: channel) { result in
            Task { @MainActor in
                switch result {
                case .upToDate:
                    self.availableUpdate = nil
                    guard !quietly else { return }
                    // A HUD that fades after a second is fine for something the
                    // user did not ask about. This is an answer to a question
                    // they asked, so it waits to be dismissed.
                    let alert = NSAlert()
                    alert.messageText = "Hangar \(Updates.bundleVersion) is current"
                    alert.informativeText =
                        "No newer release on the \(channel) channel. Hangar checks "
                        + "again automatically at most once every "
                        + "\(self.store.config.updateCheckHours ?? 24) hours."
                    alert.addButton(withTitle: "OK")
                    alert.addButton(withTitle: "Release Notes")
                    Notifier.dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertSecondButtonReturn {
                        NSWorkspace.shared.open(Updates.repoURL
                            .appendingPathComponent("releases"))
                    }
                case .available(let version, let url, let dmg):
                    self.availableUpdate = Update(version: version, page: url, dmg: dmg)
                    // Either way the answer is an offer to install. A check the
                    // user asked for goes straight to it; the daily one asks
                    // first, because nothing unprompted should start a download.
                    self.installUpdate(confirmFirst: quietly)
                case .failed(let message):
                    guard !quietly else { return }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Update check failed"
                    alert.informativeText = message
                    alert.addButton(withTitle: "OK")
                    Notifier.dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    /// Downloads, verifies and stages the new build, then asks before quitting.
    /// Nothing touches the installed app until the user says go.
    ///
    /// `confirmFirst` covers the unprompted daily check: it asks before spending
    /// the user's bandwidth. A check they asked for has already been consented to.
    func installUpdate(confirmFirst: Bool = false) {
        guard let update = availableUpdate else { return }
        guard let dmg = update.dmg else {
            NSWorkspace.shared.open(update.page)
            return
        }
        if confirmFirst {
            let ask = NSAlert()
            ask.messageText = "Hangar \(update.version) is available"
            ask.informativeText =
                "You are on \(Updates.bundleVersion). Download it and install in place? "
                + "Hangar verifies the download is notarized by Apple and signed by this "
                + "project before it replaces anything."
            ask.addButton(withTitle: "Download and Install")
            ask.addButton(withTitle: "Not Now")
            ask.addButton(withTitle: "Release Notes")
            Notifier.dismiss()
            NSApp.activate(ignoringOtherApps: true)
            switch ask.runModal() {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn: NSWorkspace.shared.open(update.page); return
            default: return
            }
        }
        let target = Bundle.main.bundleURL
        Notifier.show(title: "Downloading Hangar \(update.version)\u{2026}", seconds: 3)
        Updates.stage(dmg: dmg, replacing: target, status: { message in
            Task { @MainActor in Notifier.show(title: message, seconds: 2) }
        }, completion: { result in
            Task { @MainActor in
                switch result {
                case .failed(let message):
                    Notifier.show(title: "Update failed", body: message, seconds: 5)
                case .ready(let swap):
                    let alert = NSAlert()
                    alert.messageText = "Hangar \(update.version) is ready to install"
                    alert.informativeText =
                        "Hangar will quit, replace itself, and reopen. The download was "
                        + "verified as notarized by Apple and signed by this project."
                    alert.addButton(withTitle: "Install and Relaunch")
                    alert.addButton(withTitle: "Later")
                    Notifier.dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    swap()
                    NSApp.terminate(nil)
                }
            }
        })
    }

    /// Clears Hangar's own state after confirming exactly what goes.
    func resetState(scope: HangarReset.Scope) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = scope == .cache
            ? "Clear the cached fleet?"
            : "Reset Hangar to a fresh install?"
        alert.informativeText = HangarReset.description(of: scope)
        alert.addButton(withTitle: scope == .cache ? "Clear Cache" : "Reset Hangar")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let outcome = HangarReset.perform(scope)
        guard outcome.failed.isEmpty else {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Reset did not finish"
            failure.informativeText = outcome.failed.joined(separator: "\n")
            failure.runModal()
            return
        }

        store.reloadAfterReset()
        Notifier.show(
            title: scope == .cache ? "Cache cleared" : "Hangar reset",
            body: outcome.removed.isEmpty
                ? "There was nothing left to remove"
                : "\(outcome.removed.count) file(s) removed. Fetching the fleet\u{2026}",
            seconds: 3)
        registerHotKeys()
        scheduleRefresh()
        Task { @MainActor in
            await store.refresh()
            if scope == .everything { self.showSetup() }
        }
    }

    /// Removes everything Hangar wrote, stops opening at login, then quits and
    /// moves the bundle to the Trash. Confirmed once, because the Trash makes it
    /// recoverable and the dialog says exactly what goes.
    func uninstall() {
        // Every copy, not just the one this process is running from. A DMG
        // dragged to Applications alongside a build installed elsewhere is an
        // ordinary state, and removing one of them left the other opening at
        // login and rewriting ~/.hangar the moment it launched.
        let copies = Uninstaller.installedCopies()
        var detail = HangarUninstall.description
        if !copies.removable.isEmpty {
            detail += "\n\nThese copies will be moved to the Trash:\n"
                + InstalledCopies.describe(copies.removable)
        }
        if !copies.stuck.isEmpty {
            detail += "\n\nFound but left alone, because it is not an installed copy:\n"
                + InstalledCopies.describe(copies.stuck)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Hangar?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Uninstall Hangar")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Staged before anything is removed, so a helper that cannot be written
        // leaves the install intact rather than half gone.
        let staged: () -> Void
        switch Uninstaller.stageBundleRemoval(
            of: copies.removable.map { URL(fileURLWithPath: $0) }) {
        case .ready(let removal):
            staged = removal
        case .failed(let message):
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Uninstall did not start"
            failure.informativeText = message + "\n\nNothing was removed."
            failure.runModal()
            return
        }

        // Other instances go first: one of them would write ~/.hangar straight
        // back after the removal below, which is how an uninstall undoes itself.
        Log.info(.uninstall, "uninstall confirmed",
                 ["copies": "\(copies.removable.count)",
                  "left_in_place": "\(copies.stuck.count)"])
        Uninstaller.quitOtherInstances()

        // Unregistering needs the bundle still in place, so it goes first.
        LoginItem.set(false)
        let outcome = HangarUninstall.perform()
        guard outcome.failed.isEmpty else {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Uninstall did not finish"
            failure.informativeText = outcome.failed.joined(separator: "\n")
                + "\n\nHangar is still installed. Remove these by hand and try again."
            failure.runModal()
            return
        }

        hotKeys.unregisterAll()
        refreshTimer?.invalidate()
        updateTimer?.invalidate()
        staged()
        NSApp.terminate(nil)
    }

    /// Closing the dashboard or the setup screen puts Hangar back in the menu
    /// bar; it does not end it. Quit Hangar, in the menu bar item or the app
    /// menu, is the only thing that does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu bar actions
    //
    // Reached through the responder chain from the app's menu bar, which exists
    // only while a window is open. Each one is the same call the menubar item
    // makes, so the two menus cannot drift apart.

    @objc func menuOpenPanel() { openPanel() }
    @objc func menuRefreshFleet() { Task { @MainActor in await store.refresh() } }
    @objc func menuShowDashboard() { showDashboard() }
    @objc func menuShowSetup() { showSetup() }
    @objc func menuCheckUpdates() { checkForUpdates(quietly: false) }
    @objc func menuWriteAliases() { store.syncSSHConfig() }
    @objc func menuRevealLog() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: HangarConfig.logPath)])
    }
    @objc func menuShowAbout() { menuBar.showAboutWindow() }
    @objc func menuOpenSource() { NSWorkspace.shared.open(Updates.repoURL) }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "quitting")
        hotKeys.unregisterAll()
        refreshTimer?.invalidate()
        updateTimer?.invalidate()
    }

    /// Checks at most once every `update_check_hours`, default 24. The timer ticks
    /// hourly and usually decides it is not due yet, which is what makes the
    /// schedule survive a laptop that sleeps for most of the day.
    private func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        guard store.config.checkUpdatesOnLaunch ?? true else { return }
        let hours = store.config.updateCheckHours ?? 24
        guard hours > 0 else { return }
        checkIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in self.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard store.config.checkUpdatesOnLaunch ?? true else { return }
        guard Updates.isDue(every: store.config.updateCheckHours ?? 24) else { return }
        checkForUpdates(quietly: true)
    }

    private func openPanel() {
        panel.show(filter: [:], title: "All hosts")
    }

    /// Every hotkey in the config gets its own registration and its own filter,
    /// so cmd+shift+P can open straight into production while cmd+shift+H shows
    /// everything.
    private func registerHotKeys() {
        hotKeys.unregisterAll()
        store.reloadConfig()
        let configured = store.config.hotkeys ?? [HangarConfig.Hotkey(
            keys: "cmd+shift+h", title: "All hosts", filter: [:])]

        var failed: [String] = []
        var first: String?
        for entry in configured {
            guard let spec = HotKeyManager.parse(entry.keys) else {
                failed.append("\(entry.keys) is not a combination Hangar understands")
                continue
            }
            let filter = entry.filter ?? [:]
            let title = entry.title ?? (filter.isEmpty
                ? "All hosts"
                : filter.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
            let ok = hotKeys.register(spec) { [weak self] in
                self?.panel.toggle(filter: filter, title: title)
            }
            if !ok { failed.append("\(spec.display) is already taken by another app") }
            if first == nil { first = spec.display }
        }
        hotkeyProblems = failed
        if let first { primaryCombination = first }
        Log.info(.app, "hotkeys registered",
                 ["wanted": "\(configured.count)", "failed": "\(failed.count)",
                  "primary": first ?? "none"])
        if !failed.isEmpty {
            Notifier.show(title: "Hotkey problem", body: failed.joined(separator: "; "),
                          seconds: 5)
        }
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let minutes = max(1, store.config.refreshMinutes ?? 30)
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Double(minutes) * 60, repeats: true) { _ in
            Task { @MainActor in await self.store.refresh() }
        }
    }
}

/// `.accessory` keeps Hangar out of the Dock and the app switcher: it is a
/// menubar utility, and a Dock icon would be noise.
@main
struct HangarApp {
    @MainActor
    static func main() {
        // Build-time check that every supplied asset name resolves in the real
        // bundle. Runs before the app starts so it can be used from the Makefile.
        if CommandLine.arguments.contains("--verify-assets") {
            Brand.printVerification()
            exit(Brand.verifyAssets().isEmpty ? 0 : 1)
        }
        // Writes the composed menubar glyphs out so the two-tone health variant
        // can be inspected without hunting for it in a screenshot.
        if let index = CommandLine.arguments.firstIndex(of: "--dump-status-glyph"),
           CommandLine.arguments.count > index + 1 {
            exit(StatusGlyphDump.run(directory: CommandLine.arguments[index + 1]) ? 0 : 1)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
