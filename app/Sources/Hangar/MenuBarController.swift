import AppKit
import Combine
import HangarCore

/// The menubar item and its menu. Built fresh each time the menu opens so it
/// always reflects the current cache without needing to be invalidated.
/// Item order and wording follow the brand kit's copy deck.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: FleetStore
    private let statusItem: NSStatusItem
    private let onOpenPanel: () -> Void
    private let onReloadHotkeys: () -> Void
    private let onShowSetup: () -> Void
    private let onShowDashboard: () -> Void
    private let onCheckUpdates: () -> Void
    private let availableUpdate: () -> AppDelegate.Update?
    private let onInstallUpdate: () -> Void
    private let onReset: (HangarReset.Scope) -> Void
    private let onUninstall: () -> Void
    private var observers: [AnyCancellable] = []
    private var editor: HostEditor?
    private var about: AboutWindow?

    init(store: FleetStore, onOpenPanel: @escaping () -> Void,
         onReloadHotkeys: @escaping () -> Void,
         onShowSetup: @escaping () -> Void,
         onShowDashboard: @escaping () -> Void,
         onCheckUpdates: @escaping () -> Void,
         availableUpdate: @escaping () -> AppDelegate.Update?,
         onInstallUpdate: @escaping () -> Void,
         onReset: @escaping (HangarReset.Scope) -> Void,
         onUninstall: @escaping () -> Void) {
        self.store = store
        self.onOpenPanel = onOpenPanel
        self.onReloadHotkeys = onReloadHotkeys
        self.onShowSetup = onShowSetup
        self.onShowDashboard = onShowDashboard
        self.onCheckUpdates = onCheckUpdates
        self.availableUpdate = availableUpdate
        self.onInstallUpdate = onInstallUpdate
        self.onReset = onReset
        self.onUninstall = onUninstall
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageOnly
        updateStatusImage()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Health follows the cache, so track the fields that change it.
        store.$fetchedAt.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusImage() }
        }.store(in: &observers)
        store.$status.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusImage() }
        }.store(in: &observers)

        // A light/dark switch changes the colour the shell has to be painted in.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                StatusGlyph.invalidateCache()
                self?.updateStatusImage()
            }
        }
    }

    /// The aircraft turns green while the cache is fresh. When the menu is open
    /// or the fleet is not healthy, the unmodified template is used so macOS
    /// keeps inverting it against the highlight and the menubar appearance.
    private var menuIsOpen = false

    func updateStatusImage() {
        guard let button = statusItem.button else { return }
        let healthy = store.isHealthy && !menuIsOpen
        if healthy {
            // The menubar paints glyphs in its own foreground colour, which is
            // what labelColor resolves to under the status bar's appearance.
            var shell = Brand.Color.textPrimary
            var aircraft = Brand.Color.stateRunning
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                shell = NSColor.labelColor.usingColorSpace(.sRGB) ?? shell
                aircraft = Brand.Color.stateRunning.usingColorSpace(.sRGB) ?? aircraft
            }
            if let image = StatusGlyph.twoTone(shell: shell, aircraft: aircraft) {
                button.image = image
                button.title = ""
                button.imagePosition = .imageOnly
                button.toolTip = "Hangar: \(store.fleetSummary)"
                button.setAccessibilityLabel("Hangar, fleet healthy, \(store.fleetSummary)")
                return
            }
        }
        if let plain = StatusGlyph.plain() {
            button.image = plain
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            // A nil image on a variable-length item is an invisible, zero-width
            // button, which looks exactly like the app failing to launch.
            button.image = nil
            button.title = "Hangar"
            button.imagePosition = .noImage
        }
        button.toolTip = store.instances.isEmpty ? "Hangar" : "Hangar: \(store.fleetSummary)"
        button.setAccessibilityLabel(
            store.isHealthy ? "Hangar" : "Hangar, fleet cache is stale")
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateStatusImage()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        updateStatusImage()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = action("Open Hangar", #selector(openPanel), key: "h")
        open.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(open)
        menu.addItem(action("Refresh Fleet", #selector(refresh), key: "r"))

        // Status rows are indented and set in a smaller face so the eye separates
        // them from the actions above; regions and counts are literal, so they get
        // monospace and tabular figures.
        let fleetRow = statusRow([
            .digits("\(store.instances.count)"),
            .text(" hosts"),
        ] + (store.region.isEmpty ? [] : [.text("  ·  "), .mono(store.region)]))
        fleetRow.image = Mark.instance(size: 12)
        menu.addItem(fleetRow)

        if let age = store.cacheAgeDescription {
            let item = statusRow([.text(age)], tier: .faint)
            if store.isStale {
                item.image = Brand.Glyph.template("StaleCacheIcon", size: 12)
                item.image?.isTemplate = true
            }
            menu.addItem(item)
        }
        if case .failed(let message) = store.status {
            menu.addItem(errorRow(message))
            // Only offered when the advice actually names a command: telling a
            // static-keys user to run aws sso login would be wrong.
            if store.credentialAdvice?.command != nil {
                menu.addItem(action("Copy Login Command", #selector(copyLoginCommand), key: ""))
            }
            menu.addItem(action("Retry", #selector(refresh), key: ""))
        } else if let source = store.credentialDescription {
            var runs: [StatusRun] = [.text(source.label)]
            if let literal = source.literal { runs += [.text(" "), .mono(literal)] }
            let row = statusRow(runs, tier: .faint)
            row.image = Mark.cloud(size: 12)
            menu.addItem(row)
        }

        // An update waits here rather than interrupting: the daily check is quiet
        // by design, so this is where it surfaces.
        if let update = availableUpdate() {
            menu.addItem(.separator())
            let item = action("Install Hangar \(update.version)\u{2026}",
                              #selector(installUpdate), key: "")
            item.image = Brand.Glyph.template("StaleCacheIcon", size: 12)
            menu.addItem(item)
        }

        // Deviation from the copy deck, flagged in the handoff: the host cascade
        // is an existing feature, so it is preserved as its own section rather
        // than dropped to match the deck's ten items exactly.
        addFleet(to: menu)

        menu.addItem(.separator())
        let dashboard = action("Fleet Dashboard\u{2026}", #selector(showDashboard), key: "d")
        dashboard.image = Brand.Glyph.symbol("chart.bar.doc.horizontal", size: 13)
        menu.addItem(dashboard)
        menu.addItem(sshConfigItem())
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        menu.addItem(helpItem())
        let source = action("Source on GitHub", #selector(openSource), key: "")
        source.image = Mark.github(size: 13)
        menu.addItem(source)
        menu.addItem(action("About Hangar", #selector(showAbout), key: ""))
        menu.addItem(action("Quit Hangar", #selector(quit), key: "q"))
    }

    /// The cascade, one submenu per grouping level the fleet actually uses,
    /// under a heading so the top of the menu reads as a list of hosts rather
    /// than as more menu. `FleetGrouping` decides which levels exist, so a fleet
    /// organised by one tag gets one level rather than one real level and two
    /// empty ones.
    private func addFleet(to menu: NSMenu) {
        let section = FleetSection.classify(
            hostCount: store.instances.count,
            isRefreshing: store.status == .refreshing,
            lastFetchFailed: { if case .failed = store.status { return true } else { return false } }(),
            everReachedAWS: store.fetchedAt != nil)
        // The section owns its separator, because .hidden draws neither.
        guard section != .hidden else { return }
        menu.addItem(.separator())
        menu.addItem(fleetHeader())
        switch section {
        case .hosts:
            for node in FleetGrouping.tree(store.instances,
                                           groupBy: store.config.groupingKeys) {
                menu.addItem(item(for: node))
            }
        case .empty:
            menu.addItem(status("No hosts found."))
        case .looking:
            menu.addItem(statusRow([.text("Looking for hosts\u{2026}")], tier: .faint))
        case .neverFetched:
            menu.addItem(statusRow([.text("No inventory yet. Refresh Fleet builds one.")],
                                   tier: .faint))
        case .hidden:
            break
        }
    }

    /// "Hosts", not "Instances": the rest of the app calls them hosts, and what
    /// the row does is ssh to one.
    private func fleetHeader() -> NSMenuItem {
        let header = sectionHeader("Hosts")
        header.image = Mark.instance(size: 11)
        return header
    }


    private func item(for node: FleetGrouping.Node) -> NSMenuItem {
        switch node {
        case .group(let title, let children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for child in children { submenu.addItem(self.item(for: child)) }
            item.submenu = submenu
            item.image = Brand.Glyph.template("ProductIcon", size: 12)
            return item
        case .host(let instance):
            return hostItem(instance)
        }
    }

    private func hostItem(_ instance: Instance) -> NSMenuItem {
        let alias = store.alias(for: instance) ?? instance.aliasStem
        let label = instance.leafLabel(alias: alias, groupedBy: store.config.groupingKeys)
        let item = NSMenuItem(title: label, action: #selector(openHost(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = instance.id
        // The EC2 chip, the same mark as the count row, so every leaf reads as
        // an instance. State is carried by the label below rather than by the
        // glyph: a menu image cannot be tinted without losing the inversion
        // macOS applies to a highlighted row.
        item.image = Mark.instance(size: 12)
        if instance.state != "running" {
            item.attributedTitle = NSAttributedString(
                string: "\(label)  (\(instance.state))",
                attributes: [.foregroundColor: Brand.Color.textSecondary,
                             .font: NSFont.menuFont(ofSize: 0)])
        }
        item.toolTip = "ssh \(alias)\n\(instance.host ?? instance.id)"
            + "\n\u{2318}-click to edit ssh user or key"
        return item
    }

    private func sshConfigItem() -> NSMenuItem {
        let item = NSMenuItem(title: "SSH Config\u{2026}", action: nil, keyEquivalent: "")
        item.image = Brand.Glyph.symbol("doc.text", size: 13)
        let submenu = NSMenu()
        submenu.addItem(action("Write Aliases Now", #selector(sync), key: ""))
        if !SSHConfigWriter.includeLinePresent() {
            submenu.addItem(action("Add Include Line to ~/.ssh/config",
                                   #selector(addInclude), key: ""))
        } else {
            submenu.addItem(status("Include line present in ~/.ssh/config"))
        }
        submenu.addItem(.separator())
        submenu.addItem(status("~/.ssh/config.d/hangar"))
        item.submenu = submenu
        return item
    }

    private func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings\u{2026}", action: nil, keyEquivalent: ",")
        item.image = Brand.Glyph.symbol("gearshape", size: 13)
        let submenu = NSMenu()

        // Grouped by what the item is about, because a flat list mixed a toggle,
        // a submenu, an action and a destructive reset with no order to it.
        submenu.addItem(sectionHeader("Account", symbol: "person.crop.circle"))
        submenu.addItem(profileMenuItem())

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Startup", symbol: "power"))
        let login = action("Open Hangar at Login", #selector(toggleLoginItem), key: "")
        login.state = LoginItem.isEnabled ? .on : .off
        submenu.addItem(login)
        submenu.addItem(statusRow([.text(LoginItem.statusDescription)], tier: .faint))

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Updates", symbol: "arrow.down.circle"))
        let daily = action("Check Daily", #selector(toggleDailyUpdates), key: "")
        daily.state = (store.config.checkUpdatesOnLaunch ?? true) ? .on : .off
        submenu.addItem(daily)
        submenu.addItem(updateChannelItem())
        submenu.addItem(action("Check Now\u{2026}", #selector(checkUpdates), key: ""))
        // The version belongs next to the thing that changes it, so "is there
        // anything newer" can be answered without opening About.
        var versionRuns: [StatusRun] = [.text("Version "), .mono(Updates.bundleVersion)]
        if let update = availableUpdate() {
            versionRuns += [.text("  \u{2192}  "), .mono(update.version), .text(" available")]
        } else if let checked = Updates.lastCheck {
            versionRuns.append(.text("  ·  checked \(MenuBarController.ago(checked))"))
        }
        submenu.addItem(statusRow(versionRuns, tier: .faint))

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Configuration", symbol: "slider.horizontal.3"))
        submenu.addItem(action("Setup Check\u{2026}", #selector(showSetup), key: ""))
        submenu.addItem(action("Edit Configuration\u{2026}", #selector(editConfig), key: ""))
        submenu.addItem(status("~/.hangar/config.json"))
        submenu.addItem(action("Reveal Log in Finder", #selector(revealLog), key: ""))
        submenu.addItem(status("~/.hangar/logs/hangar.log"))

        // Last, and behind its own heading: both of these throw work away.
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Start Over", symbol: "exclamationmark.triangle"))
        let clear = action("Clear Fleet Cache\u{2026}", #selector(clearCache), key: "")
        clear.image = Brand.Glyph.symbol("arrow.clockwise.circle", size: 13)
        submenu.addItem(clear)
        let reset = action("Reset Hangar\u{2026}", #selector(resetEverything), key: "")
        reset.image = Brand.Glyph.symbol("exclamationmark.arrow.circlepath", size: 13)
        submenu.addItem(reset)

        // Its own section rather than a third row under Start Over: a reset is
        // something you do to keep using Hangar, an uninstall is not.
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Uninstall", symbol: "trash"))
        let uninstall = action("Uninstall Hangar\u{2026}", #selector(uninstallHangar), key: "")
        uninstall.image = Brand.Glyph.symbol("trash", size: 13)
        submenu.addItem(uninstall)
        submenu.addItem(statusRow([.text("Removes Hangar's files and every installed copy")],
                                  tier: .faint))

        item.submenu = submenu
        return item
    }

    private func profileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "AWS Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let files = AWSConfigFiles.load()
        let active = store.config.profile
        let auto = NSMenuItem(title: "Automatic", action: #selector(pickProfile(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.state = active == nil ? .on : .off
        submenu.addItem(auto)
        submenu.addItem(.separator())
        for name in files.profileNames {
            let profileItem = NSMenuItem(title: name, action: #selector(pickProfile(_:)),
                                         keyEquivalent: "")
            profileItem.target = self
            profileItem.representedObject = name
            profileItem.state = active == name ? .on : .off
            submenu.addItem(profileItem)
        }
        item.submenu = submenu
        return item
    }

    /// A run of status text. `mono` marks values the user might copy or type:
    /// regions, profile names, paths. `digits` keeps counts from shifting width.
    /// `keys` is for a shortcut we want someone to actually notice and learn.
    enum StatusRun {
        case text(String)
        case mono(String)
        case digits(String)
        case keys(String)
    }

    /// Two tiers of emphasis below the actions, so a stack of disabled rows does
    /// not read as one grey block.
    enum StatusTier {
        case normal, faint

        var color: NSColor {
            switch self {
            case .normal: return Brand.Color.textSecondary
            // Derived from the brand secondary rather than a new colour: the
            // catalog has no third text tier.
            case .faint:  return Brand.Color.textSecondary.withAlphaComponent(0.62)
            }
        }
    }

    private func statusRow(_ runs: [StatusRun], tier: StatusTier = .normal,
                           size: CGFloat = 12) -> NSMenuItem {
        let result = NSMutableAttributedString()
        for run in runs {
            let (string, font): (String, NSFont) = {
                switch run {
                case .text(let value):
                    return (value, .systemFont(ofSize: size, weight: .regular))
                case .mono(let value):
                    return (value, .monospacedSystemFont(ofSize: size, weight: .regular))
                case .digits(let value):
                    return (value, .monospacedDigitSystemFont(ofSize: size, weight: .medium))
                case .keys(let value):
                    // Bigger and medium weight so the one shortcut worth
                    // memorising carries the row instead of hiding in it.
                    return (value, .monospacedSystemFont(ofSize: size + 3, weight: .medium))
                }
            }()
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: tier.color,
            ]
            if case .keys = run { attributes[.kern] = 2.0 }
            let piece = NSMutableAttributedString(string: string, attributes: attributes)
            // Kerning applies AFTER every character, so the last glyph would
            // push the following text an extra 2pt out. Strip it there.
            if case .keys = run, piece.length > 0 {
                piece.removeAttribute(.kern, range: NSRange(location: piece.length - 1, length: 1))
            }
            result.append(piece)
        }
        let item = NSMenuItem(title: result.string, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = result
        item.indentationLevel = 1
        return item
    }

    private func status(_ title: String) -> NSMenuItem {
        statusRow([.text(title)])
    }

    /// Stable sees only full releases; beta also offers prereleases.
    private func updateChannelItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Update Channel", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let active = (store.config.updateChannel ?? "stable").lowercased()
        for (channel, label) in [("stable", "Stable releases"), ("beta", "Beta releases")] {
            let entry = NSMenuItem(title: label, action: #selector(pickChannel(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = channel
            entry.state = active == channel ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// Everything a new user needs in one place: the one shortcut that starts it
    /// all, then the keys, then the two things that are not discoverable.
    /// Everything a new user needs in one place: the one shortcut that starts it
    /// all, then the keys, then the two things that are not discoverable.
    ///
    /// Every row carries a glyph. Fifteen rows of grey text at one size reads as
    /// a wall and gets skipped; an icon per row gives the eye somewhere to land
    /// and makes the shape of each section legible before a word is read.
    private func helpItem() -> NSMenuItem {
        // Help is prose to be read, not a status line to be glanced at, so it sits
        // a size and a half above the status rows.
        let help: CGFloat = 13.5
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        item.image = Brand.Glyph.symbol("questionmark.circle", size: 13)
        let submenu = NSMenu()

        func row(_ runs: [StatusRun], tier: StatusTier = .normal,
                 symbol: String? = nil, glyph: NSImage? = nil) -> NSMenuItem {
            let entry = statusRow(runs, tier: tier, size: help)
            entry.image = glyph ?? symbol.flatMap { Brand.Glyph.symbol($0, size: 12) }
            return entry
        }

        submenu.addItem(sectionHeader("It all starts with one shortcut",
                                      symbol: "bolt.fill"))
        submenu.addItem(row([.keys("\u{2318}\u{21E7}H"),
                             .text("   from any app, anywhere")],
                            symbol: "keyboard"))
        submenu.addItem(row([.text("Type a few characters in any order. "),
                             .mono("payments web qa")],
                            tier: .faint, symbol: "magnifyingglass"))
        submenu.addItem(row([.text("The first match is already selected, so "),
                             .mono("\u{21A9}"), .text(" connects.")],
                            tier: .faint, symbol: "sparkle.magnifyingglass"))

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("In the panel", symbol: "rectangle.and.text.magnifyingglass"))
        for (key, what, symbol) in [
            ("\u{21A9}", "Connect in your terminal", "arrow.turn.down.left"),
            ("\u{2318}\u{21A9}", "Copy the ssh command instead", "doc.on.doc"),
            ("\u{2318}E", "Edit this host's ssh user or key", "pencil"),
            ("\u{2318}R", "Refresh the fleet from AWS", "arrow.clockwise"),
            ("\u{2191} \u{2193}", "Move the selection", "arrow.up.arrow.down"),
            ("esc", "Close the panel, Hangar keeps running", "escape"),
        ] {
            submenu.addItem(row([.mono(key.padding(toLength: max(key.count, 4),
                                                   withPad: " ", startingAt: 0)),
                                 .text("   " + what)],
                                symbol: symbol))
        }

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("When a login does not work",
                                      symbol: "person.badge.key"))
        submenu.addItem(row([
            .text("Hold "), .mono("\u{2318}"),
            .text(" and click a host, here or in the panel."),
        ], tier: .faint, symbol: "cursorarrow.click"))
        submenu.addItem(row([
            .text("Detect Login tries the usual cloud logins and keeps the one that works."),
        ], tier: .faint, symbol: "wand.and.stars"))

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Aliases outside Hangar", symbol: "terminal"))
        submenu.addItem(row([.mono("ssh payments-prod-web-1"),
                             .text("  works in any terminal")],
                            tier: .faint, symbol: "chevron.left.forwardslash.chevron.right"))
        submenu.addItem(row([
            .text("Also scp, rsync, Ansible, and VS Code Remote."),
        ], tier: .faint, symbol: "arrow.left.arrow.right"))

        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Your fleet", symbol: "square.grid.2x2"))
        submenu.addItem(row([.text("Grouped by "), .mono("product"), .text(", then "),
                             .mono("env"), .text(", from your instance tags.")],
                            tier: .faint, glyph: Brand.Glyph.template("ProductIcon", size: 12)))
        submenu.addItem(row([
            .text("Different tag names? Map them in ~/.hangar/config.json."),
        ], tier: .faint, glyph: Brand.Glyph.template("EnvironmentIcon", size: 12)))
        submenu.addItem(row([.text("The aircraft turns green while the cache is fresh.")],
                            tier: .faint, glyph: Brand.Glyph.template("RunningIcon", size: 12)))

        submenu.addItem(.separator())
        let setup = action("Setup Check\u{2026}", #selector(showSetup), key: "")
        setup.image = Brand.Glyph.symbol("checkmark.seal", size: 13)
        submenu.addItem(setup)
        let source = action("Source on GitHub", #selector(openSource), key: "")
        source.image = Mark.github(size: 13)
        submenu.addItem(source)
        item.submenu = submenu
        return item
    }

    /// "2 min ago", for the line under Check for Updates.
    static func ago(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 90 { return "just now" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = elapsed < 3600 ? [.minute]
            : (elapsed < 86400 ? [.hour] : [.day])
        formatter.maximumUnitCount = 1
        guard let age = formatter.string(from: elapsed) else { return "recently" }
        return "\(age) ago"
    }

    private func sectionHeader(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: Brand.Color.textSecondary,
                         .kern: 0.4])
        item.image = symbol.flatMap { Brand.Glyph.symbol($0, size: 11, weight: .semibold) }
        return item
    }

    @objc private func toggleLoginItem() {
        let turningOn = !LoginItem.isEnabled
        let problem = LoginItem.set(turningOn)
        var config = store.config
        config.launchAtLogin = turningOn
        try? HangarConfig.write(config)
        store.reloadConfig()
        Notifier.show(title: turningOn ? "Opens at login" : "No longer opens at login",
                      body: problem ?? LoginItem.statusDescription,
                      seconds: problem == nil ? 2 : 4)
    }

    @objc private func showSetup() { onShowSetup() }
    @objc private func showDashboard() { onShowDashboard() }
    @objc private func checkUpdates() { onCheckUpdates() }
    @objc private func openSource() { NSWorkspace.shared.open(Updates.repoURL) }

    @objc private func toggleDailyUpdates() {
        var config = store.config
        let turningOn = !(config.checkUpdatesOnLaunch ?? true)
        config.checkUpdatesOnLaunch = turningOn
        try? HangarConfig.write(config)
        store.reloadConfig()
        Notifier.show(
            title: turningOn ? "Checking for updates daily" : "Automatic checks off",
            body: turningOn
                ? "At most once every \(store.config.updateCheckHours ?? 24) hours"
                : "Use Check for Updates when you want one",
            seconds: 3)
    }

    @objc private func pickChannel(_ sender: NSMenuItem) {
        var config = store.config
        config.updateChannel = sender.representedObject as? String
        try? HangarConfig.write(config)
        store.reloadConfig()
    }

    private func errorRow(_ message: String) -> NSMenuItem {
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: message,
            attributes: [.foregroundColor: Brand.Color.stateTerminated,
                         .font: NSFont.menuFont(ofSize: 0)])
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func openPanel() { onOpenPanel() }

    @objc private func refresh() {
        Task { @MainActor in
            await store.refresh()
            if case .failed(let message) = store.status {
                Notifier.show(title: "Refresh failed", body: message, seconds: 3)
            } else {
                Notifier.show(title: store.fleetSummary, body: nil)
            }
        }
    }

    @objc private func sync() {
        store.syncSSHConfig()
        Notifier.show(title: "SSH config updated",
                      body: store.lastSyncMessage, seconds: 3)
    }

    @objc private func addInclude() {
        do {
            try SSHConfigWriter.addIncludeLine()
            Notifier.show(title: "Include line added",
                          body: "~/.ssh/config now includes ~/.ssh/config.d/hangar")
        } catch {
            Notifier.show(title: "Could not edit ~/.ssh/config",
                          body: error.localizedDescription, seconds: 3)
        }
    }

    @objc private func openHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let instance = store.instances.first(where: { $0.id == id }) else { return }
        if NSEvent.modifierFlags.contains(.command) {
            let alias = store.alias(for: instance) ?? instance.aliasStem
            let editor = HostEditor(store: store, instance: instance,
                                    alias: alias) { [weak self] message in
                Notifier.show(title: "SSH settings", body: message, seconds: 3)
                self?.editor = nil
            }
            self.editor = editor
            editor.show()
            return
        }
        let (command, _) = store.sshTarget(for: instance)
        if NSEvent.modifierFlags.contains(.option) {
            Launcher.copyToClipboard(command)
            Notifier.show(title: "Copied", body: command)
            return
        }
        if let problem = Launcher.open(command: command,
                                       in: Launcher.Terminal.from(store.config.terminal)) {
            Notifier.show(title: "Could not open a terminal", body: problem, seconds: 4)
        }
    }

    @objc private func pickProfile(_ sender: NSMenuItem) {
        var config = store.config
        config.profile = sender.representedObject as? String
        try? HangarConfig.write(config)
        store.reloadConfig()
        Task { @MainActor in await store.refresh() }
    }

    @objc private func copyLoginCommand() {
        guard let command = store.credentialAdvice?.command else { return }
        Launcher.copyToClipboard(command)
        Notifier.show(title: "Copied", body: command)
    }

    /// Opens the config in a plain text editor. The default handler for .json is
    /// often Xcode, which is far too heavy for editing a few keys.
    @objc private func editConfig() {
        let url = URL(fileURLWithPath: HangarConfig.path)
        let configuration = NSWorkspace.OpenConfiguration()
        if let editor = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: editor,
                                    configuration: configuration) { _, error in
                if error != nil { NSWorkspace.shared.open(url) }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() { showAboutWindow() }

    /// Also reached from the app menu bar's About item, so both routes open the
    /// same window rather than the standard panel.
    func showAboutWindow() {
        let window = AboutWindow { [weak self] in self?.about = nil }
        about = window
        window.show()
    }

    @objc private func installUpdate() { onInstallUpdate() }
    @objc private func clearCache() { onReset(.cache) }
    @objc private func resetEverything() { onReset(.everything) }
    @objc private func uninstallHangar() { onUninstall() }

    /// Reveals rather than opens: the log is a growing file, and Finder is where
    /// someone goes to attach it to a bug report.
    @objc private func revealLog() {
        let path = HangarConfig.logPath
        if !FileManager.default.fileExists(atPath: path) {
            Log.info(.app, "log revealed before anything was written")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
