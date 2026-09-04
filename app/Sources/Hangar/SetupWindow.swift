import AppKit
import HangarCore

/// First-run setup check, and the same window later from the menubar.
///
/// Everything Hangar needs is already on the machine, so rather than a wizard that
/// asks questions, this reads the actual setup and says what works and what does
/// not, with a fix beside anything actionable.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private let store: FleetStore
    private let hotkeyProblem: () -> String?
    private let hotkeyCombination: () -> String
    private let onOpenPanel: () -> Void

    private var window: NSWindow!
    private var headline: NSTextField!
    private var body: NSTextField!
    private var checksStack: NSStackView!
    private var content: NSView!
    private var document: NSView!
    private var footer: NSStackView!
    private var syncToggle: NSButton!
    private var loginToggle: NSButton!
    private var updateToggle: NSButton!
    private var channelPopup: NSPopUpButton!
    private var terminalPopup: NSPopUpButton!
    private var tagsStack: NSStackView!
    private var tagsCard: NSView!
    private var tagPopups: [TagCatalog.Concept: NSPopUpButton] = [:]
    private var levelsStack: NSStackView!
    private var levelsCard: NSView!
    private var sourcesStack: NSStackView!
    private var sourcesCard: NSView!
    private var sourceToggles: [HostSource: NSButton] = [:]
    private var keyPopup: NSPopUpButton?
    private var keyAgent: SSHAgent?
    private var closeHint: NSTextField!
    private var openButton: NSButton!
    private var recheckButton: NSButton!
    private var running = false

    /// Keys the remembered frame in the standard defaults, so the window opens
    /// where it was last left rather than in the middle of whatever is there.
    private static let frameName = "HangarSetupWindow"

    init(store: FleetStore,
         hotkeyProblem: @escaping () -> String?,
         hotkeyCombination: @escaping () -> String,
         onOpenPanel: @escaping () -> Void) {
        self.store = store
        self.hotkeyProblem = hotkeyProblem
        self.hotkeyCombination = hotkeyCombination
        self.onOpenPanel = onOpenPanel
        super.init()
        build()
    }

    // MARK: - Construction

    private func build() {
        let window = HangarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Hangar Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self

        // No app icon beside the lockup: the lockup is a lockup, mark and all,
        // so the two together drew the hangar symbol twice, at two different
        // weights, an inch apart. The supplied artwork wins.
        let lockup = NSImageView()
        lockup.image = Brand.Glyph.wordmark(width: 172)
        lockup.contentTintColor = Brand.Color.textPrimary
        lockup.imageScaling = .scaleProportionallyUpOrDown
        lockup.setAccessibilityLabel("Hangar")

        headline = NSTextField(labelWithString: "Checking your setup\u{2026}")
        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        headline.textColor = Brand.Color.textPrimary

        body = NSTextField(wrappingLabelWithString:
            "Hangar reads AWS profiles and cached credentials from your home directory. "
            + "Nothing is uploaded, and no Hangar account is required.")
        body.font = Brand.Font.metadata
        body.textColor = Brand.Color.textSecondary

        checksStack = NSStackView()
        checksStack.orientation = .vertical
        checksStack.alignment = .leading
        checksStack.spacing = Brand.Metric.space8

        // The tag picker. Hidden until a fetch has told us which keys exist,
        // because an empty picker teaches nothing.
        tagsStack = NSStackView()
        tagsStack.orientation = .vertical
        tagsStack.alignment = .leading
        tagsStack.spacing = Brand.Metric.space8
        tagsStack.translatesAutoresizingMaskIntoConstraints = false

        let tagsCard = NSView()
        tagsCard.wantsLayer = true
        tagsCard.layer?.cornerRadius = 8
        tagsCard.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        tagsCard.translatesAutoresizingMaskIntoConstraints = false
        tagsCard.addSubview(tagsStack)
        NSLayoutConstraint.activate([
            tagsStack.topAnchor.constraint(equalTo: tagsCard.topAnchor,
                                           constant: Brand.Metric.space12),
            tagsStack.bottomAnchor.constraint(equalTo: tagsCard.bottomAnchor,
                                              constant: -Brand.Metric.space12),
            tagsStack.leadingAnchor.constraint(equalTo: tagsCard.leadingAnchor,
                                               constant: Brand.Metric.space12),
            tagsStack.trailingAnchor.constraint(equalTo: tagsCard.trailingAnchor,
                                                constant: -Brand.Metric.space12),
        ])
        tagsCard.isHidden = true
        self.tagsCard = tagsCard

        // Menu levels, composed by the user. Same card treatment.
        levelsStack = NSStackView()
        levelsStack.orientation = .vertical
        levelsStack.alignment = .leading
        levelsStack.spacing = Brand.Metric.space4
        levelsStack.translatesAutoresizingMaskIntoConstraints = false

        let levelsCard = NSView()
        levelsCard.wantsLayer = true
        levelsCard.layer?.cornerRadius = 8
        levelsCard.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        levelsCard.translatesAutoresizingMaskIntoConstraints = false
        levelsCard.addSubview(levelsStack)
        NSLayoutConstraint.activate([
            levelsStack.topAnchor.constraint(equalTo: levelsCard.topAnchor,
                                             constant: Brand.Metric.space12),
            levelsStack.bottomAnchor.constraint(equalTo: levelsCard.bottomAnchor,
                                                constant: -Brand.Metric.space12),
            levelsStack.leadingAnchor.constraint(equalTo: levelsCard.leadingAnchor,
                                                 constant: Brand.Metric.space12),
            levelsStack.trailingAnchor.constraint(equalTo: levelsCard.trailingAnchor,
                                                  constant: -Brand.Metric.space12),
        ])
        levelsCard.isHidden = true
        self.levelsCard = levelsCard

        // Hosts and keys. Detection, not a form: every row here is something
        // Hangar found, with the answer already chosen when there is only one.
        sourcesStack = NSStackView()
        sourcesStack.orientation = .vertical
        sourcesStack.alignment = .leading
        sourcesStack.spacing = Brand.Metric.space8
        sourcesStack.translatesAutoresizingMaskIntoConstraints = false

        let sourcesCard = NSView()
        sourcesCard.wantsLayer = true
        sourcesCard.layer?.cornerRadius = 8
        sourcesCard.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        sourcesCard.translatesAutoresizingMaskIntoConstraints = false
        sourcesCard.addSubview(sourcesStack)
        NSLayoutConstraint.activate([
            sourcesStack.topAnchor.constraint(equalTo: sourcesCard.topAnchor,
                                              constant: Brand.Metric.space12),
            sourcesStack.bottomAnchor.constraint(equalTo: sourcesCard.bottomAnchor,
                                                 constant: -Brand.Metric.space12),
            sourcesStack.leadingAnchor.constraint(equalTo: sourcesCard.leadingAnchor,
                                                  constant: Brand.Metric.space12),
            sourcesStack.trailingAnchor.constraint(equalTo: sourcesCard.trailingAnchor,
                                                   constant: -Brand.Metric.space12),
        ])
        sourcesCard.isHidden = true
        self.sourcesCard = sourcesCard

        let disclosure = NSTextField(wrappingLabelWithString:
            "Reads ~/.aws/config, ~/.aws/credentials, the SSO token cache, EC2 "
            + "instance tags and ~/.ssh/config. Writes ~/.ssh/config.d/hangar. "
            + "Never reads a private key.")
        disclosure.font = .systemFont(ofSize: 10, weight: .regular)
        disclosure.textColor = Brand.Color.textSecondary

        syncToggle = NSButton(checkboxWithTitle: "Write SSH config aliases",
                              target: self, action: #selector(toggleSync))
        syncToggle.state = (store.config.syncSSHConfigOnRefresh ?? true) ? .on : .off
        syncToggle.font = Brand.Font.metadata

        // A menubar utility is only useful if it is running, so this is offered up
        // front rather than buried, but it stays opt-in.
        loginToggle = NSButton(checkboxWithTitle: "Open Hangar at login",
                               target: self, action: #selector(toggleLogin))
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        loginToggle.font = Brand.Font.metadata

        // Automatic updates and the channel sit next to each other: turning the
        // check on is the moment someone cares which releases it sees.
        updateToggle = NSButton(checkboxWithTitle: "Check for updates daily",
                                target: self, action: #selector(toggleUpdates))
        updateToggle.state = (store.config.checkUpdatesOnLaunch ?? true) ? .on : .off
        updateToggle.font = Brand.Font.metadata

        channelPopup = NSPopUpButton()
        channelPopup.addItems(withTitles: ["Stable releases", "Beta releases"])
        channelPopup.selectItem(at:
            (store.config.updateChannel ?? "stable").lowercased() == "beta" ? 1 : 0)
        channelPopup.target = self
        channelPopup.action = #selector(channelChanged)
        channelPopup.setAccessibilityLabel("Update channel")
        channelPopup.controlSize = .small
        channelPopup.font = Brand.Font.metadata

        // Beside the other settings rather than in a card: the terminal is one
        // choice, it never grows with the fleet, and it belongs where the user
        // is already deciding how Hangar behaves.
        terminalPopup = NSPopUpButton()
        terminalPopup.controlSize = .small
        terminalPopup.font = Brand.Font.metadata
        terminalPopup.setAccessibilityLabel("Terminal")
        terminalPopup.target = self
        terminalPopup.action = #selector(terminalChanged)

        closeHint = NSTextField(labelWithString:
            "Closing this window leaves Hangar running in your menu bar.")
        closeHint.font = .systemFont(ofSize: 10, weight: .regular)
        closeHint.textColor = Brand.Color.textSecondary

        recheckButton = NSButton(title: "Re-check", target: self, action: #selector(recheck))
        openButton = NSButton(title: "Open Hangar", target: self, action: #selector(openPanel))
        openButton.keyEquivalent = "\r"
        // Close rather than Source: by the time this window is up, the menubar item
        // is already there, and closing is the thing a person actually wants next.
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\u{1b}"
        for button in [recheckButton!, openButton!, closeButton] {
            button.bezelStyle = .rounded
        }

        let titleBlock = NSStackView(views: [lockup, headline, body])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = Brand.Metric.space4
        titleBlock.setCustomSpacing(Brand.Metric.space8, after: lockup)

        let header = NSStackView(views: [titleBlock])
        header.orientation = .horizontal
        header.alignment = .top

        // All three sit together on the right, in the order macOS expects: the
        // utility first, then the dismiss, then the default action last.
        let rightButtons = NSStackView(views: [recheckButton, closeButton, openButton])
        rightButtons.orientation = .horizontal
        rightButtons.spacing = Brand.Metric.space8
        let buttonRow = NSStackView(views: [NSView(), rightButtons])
        buttonRow.orientation = .horizontal

        let toggles = NSStackView(views: [syncToggle, loginToggle])
        toggles.orientation = .horizontal
        toggles.spacing = Brand.Metric.space24

        let updateRow = NSStackView(views: [updateToggle, channelPopup])
        updateRow.orientation = .horizontal
        updateRow.spacing = Brand.Metric.space8

        let terminalLabel = NSTextField(labelWithString: "Open sessions in")
        terminalLabel.font = Brand.Font.metadata
        terminalLabel.textColor = Brand.Color.textSecondary
        let terminalRow = NSStackView(views: [terminalLabel, terminalPopup])
        terminalRow.orientation = .horizontal
        terminalRow.spacing = Brand.Metric.space8
        terminalRow.alignment = .centerY

        // Everything that grows with the fleet scrolls. The toggles and the buttons
        // are pinned below it, because a window taller than the screen with the
        // settings and Open Hangar off the bottom edge cannot be finished.
        let scrollable = NSStackView(views: [header, checksStack, sourcesCard, tagsCard,
                                             levelsCard, disclosure])
        scrollable.orientation = .vertical
        scrollable.alignment = .leading
        scrollable.spacing = Brand.Metric.space12
        scrollable.edgeInsets = NSEdgeInsets(top: Brand.Metric.space16,
                                             left: Brand.Metric.space16,
                                             bottom: Brand.Metric.space16,
                                             right: Brand.Metric.space16)
        scrollable.translatesAutoresizingMaskIntoConstraints = false

        // The stack cannot be the documentView directly: a scroll view gives its
        // document no width, so every row collapses to its intrinsic size and the
        // wrapping labels render as nothing. A flipped container pinned to the clip
        // view's width fixes both the width and the top-down row order.
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollable)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = container
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollable.topAnchor.constraint(equalTo: container.topAnchor),
            scrollable.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollable.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollable.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let footer = NSStackView(views: [toggles, updateRow, terminalRow,
                                         closeHint, buttonRow])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = Brand.Metric.space12
        footer.edgeInsets = NSEdgeInsets(top: Brand.Metric.space12,
                                         left: Brand.Metric.space16,
                                         bottom: Brand.Metric.space16,
                                         right: Brand.Metric.space16)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Dropping a CSV on the window is the import. No wizard, no file picker
        // in the common case.
        let content = DropView()
        content.onDrop = { [weak self] url in
            guard let self else { return }
            Task { await self.importHosts(from: url) }
        }
        content.addSubview(scroll)
        content.addSubview(divider)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            lockup.widthAnchor.constraint(equalToConstant: 154),
            lockup.heightAnchor.constraint(equalToConstant: 35),
            header.widthAnchor.constraint(equalTo: scrollable.widthAnchor,
                                          constant: -Brand.Metric.space32),
            checksStack.widthAnchor.constraint(equalTo: scrollable.widthAnchor,
                                               constant: -Brand.Metric.space32),
            sourcesCard.widthAnchor.constraint(equalTo: scrollable.widthAnchor,
                                               constant: -Brand.Metric.space32),
            tagsCard.widthAnchor.constraint(equalTo: scrollable.widthAnchor,
                                            constant: -Brand.Metric.space32),
            levelsCard.widthAnchor.constraint(equalTo: scrollable.widthAnchor,
                                              constant: -Brand.Metric.space32),
            disclosure.widthAnchor.constraint(equalTo: scrollable.widthAnchor,
                                              constant: -Brand.Metric.space32),
            buttonRow.widthAnchor.constraint(equalTo: footer.widthAnchor,
                                             constant: -Brand.Metric.space32),
        ])

        window.contentView = content
        // Resizable vertically only: the wrapping labels are laid out for this width.
        window.contentMinSize = NSSize(width: 600, height: 360)
        window.contentMaxSize = NSSize(width: 600, height: 20_000)
        // Reopen where it was left. Centring every time moved the window out from
        // under whoever had put it somewhere deliberate.
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        self.content = content
        self.document = container
        self.footer = footer
        self.window = window
    }

    /// Grow to fit the checks and the cards, but never past the screen. The cards
    /// only exist after a fetch, so the honest height is not known at build time.
    private func fitToScreen() {
        content.layoutSubtreeIfNeeded()
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let ceiling = max(window.contentMinSize.height, visible - 80)
        let needed = min(document.frame.height + footer.fittingSize.height + 1, ceiling)
        var frame = window.frame
        let current = window.contentRect(forFrameRect: frame).height
        // Only grow, or pull back a window that no longer fits: a height the user
        // chose by dragging is left alone.
        guard needed > current + 1 || current > ceiling + 1 else { return }
        let delta = needed - current
        frame.origin.y -= delta
        frame.size.height += delta
        if let screen = window.screen ?? NSScreen.main {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    func show() {
        // The menu bar is reference counted against the open windows, so a second
        // install for a window already on screen would leave the menu behind after
        // that window closed.
        if !window.isVisible { AppMainMenu.install() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await runChecks() }
    }

    func windowWillClose(_ notification: Notification) {
        // Only ever offered unprompted once; after that it lives in the menu.
        HangarConfig.markOnboarded()
        AppMainMenu.release()
        // A menubar app that closes its only window looks like it quit. Say where
        // it went, and how to get it back.
        Notifier.show(title: "Hangar is in your menu bar",
                      body: "Press \(hotkeyCombination()) from any app", seconds: 3)
    }

    // MARK: - Checks

    @objc private func recheck() { Task { await runChecks() } }

    /// The steps in the order they run. The window shows this list from the first
    /// frame and fills it in, because the checks are not instant: resolving
    /// credentials talks to AWS, and until this existed the window sat on
    /// "Checking your setup" over an empty sheet for as long as that took.
    private static let plan: [(title: String, detail: String)] = [
        ("AWS profiles", "Reading ~/.aws/config and ~/.aws/credentials."),
        ("Credentials", "Resolving your profile, then asking EC2 for the fleet."),
        ("Where the hosts came from", "EC2, Systems Manager, ~/.ssh/config, your CSV."),
        ("Hosts and tags", "Indexing what came back."),
        ("SSH key", "Looking for an agent holding it, then in ~/.ssh."),
        ("SSH aliases", "Looking for Hangar's include in ~/.ssh/config."),
        ("Terminal", "Looking for iTerm2 and Terminal."),
        ("Shortcut", "Checking the shortcut is free."),
    ]

    private func runChecks() async {
        guard !running else { return }
        running = true
        recheckButton.isEnabled = false
        headline.stringValue = "Checking your setup\u{2026}"

        var checks: [Preflight.Check] = []
        renderProgress(checks)

        let files = AWSConfigFiles.load()
        checks.append(Preflight.profilesCheck(files, using: store.config.profile))
        renderProgress(checks)

        // Refreshing is the honest credential and connectivity test: it does exactly
        // what Hangar does in normal use.
        await store.refresh()
        checks.append(Preflight.credentialsCheck(
            sourceLabel: store.credentialDescription.map { description in
                [description.label, description.literal].compactMap { $0 }.joined(separator: " ")
            },
            advice: store.credentialAdvice,
            hasHostsAnyway: !store.instances.isEmpty))
        renderProgress(checks)

        checks.append(Preflight.sourcesCheck(store.sourceReports,
                                             fleetSize: store.instances.count))
        renderProgress(checks)

        checks.append(Preflight.taggingCheck(instances: store.instances))
        renderProgress(checks)

        // Detected here rather than on the refresh timer: it runs a process, and
        // a fleet refreshing every half hour is no reason to keep poking at
        // somebody's vault.
        adoptTheOnlyKeyIfUnset()
        store.detectAgents()
        checks.append(Preflight.keyCheck(agents: store.agents,
                                         keyFiles: KeySource.detectKeyFiles(),
                                         settings: store.config.ssh))
        renderProgress(checks)

        let includeFileExists = FileManager.default
            .fileExists(atPath: HangarConfig.sshIncludePath)
        checks.append(Preflight.sshIncludeCheck(
            includePresent: SSHConfigWriter.includeLinePresent(),
            fileExists: includeFileExists,
            hostCount: store.writtenHostCount,
            importedCount: store.importedHostCount))
        renderProgress(checks)

        checks.append(Preflight.terminalCheck(configured: store.terminal,
                                              installed: Launcher.installed))
        renderProgress(checks)

        checks.append(Preflight.hotkeyCheck(problem: hotkeyProblem(),
                                            combination: hotkeyCombination()))

        renderTerminalPopup()

        let preflight = Preflight(checks: checks)
        switch preflight.worst {
        case .ok:
            headline.stringValue = "Hangar is ready."
            body.stringValue = "Press \(hotkeyCombination()), type a host, and press "
                + "Return to connect. Press Command-Return to copy the ssh command."
        case .warning:
            headline.stringValue = "Hangar is ready, with notes."
            body.stringValue = "Everything below works. The warnings are optional "
                + "improvements, not blockers."
        case .problem:
            headline.stringValue = "Hangar needs one thing fixed."
            body.stringValue = "Resolve the item marked below, then re-check."
        }
        render(checks)
        renderSources()
        renderTagPicker()
        renderLevels()
        fitToScreen()
        recheckButton.isEnabled = true
        running = false
    }

    /// Adopts the only key there is.
    ///
    /// The whole point of the feature: an agent holding exactly one key, and a
    /// user who has expressed no preference, is not a question worth asking.
    /// Anything else waits for a click.
    private func adoptTheOnlyKeyIfUnset() {
        guard let adopted = store.adoptAgentKeyIfUnset() else { return }
        Notifier.show(title: "Using the ssh key from your agent",
                      body: adopted, seconds: 4)
    }

    /// Where the hosts came from, and which key gets used. Every row is something
    /// Hangar found; nothing here is a path to type.
    private func renderSources() {
        sourcesStack.subviews.forEach { $0.removeFromSuperview() }
        sourceToggles = [:]
        keyPopup = nil
        keyAgent = nil
        sourcesCard.isHidden = false

        let title = NSTextField(labelWithString: "Where your hosts come from")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Brand.Color.textPrimary
        sourcesStack.addView(title, in: .top)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Hangar gathers from four places and merges them, richest first. "
            + "A source that finds nothing costs nothing, so they are all on.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Brand.Color.textSecondary
        subtitle.preferredMaxLayoutWidth = 520
        sourcesStack.addView(subtitle, in: .top)

        let grid = NSGridView()
        grid.rowSpacing = Brand.Metric.space4
        grid.columnSpacing = Brand.Metric.space12
        let reports = Dictionary(uniqueKeysWithValues:
            store.sourceReports.map { ($0.source, $0) })

        for source in FleetMerge.priority {
            let report = reports[source]
            let toggle = NSButton(checkboxWithTitle: source.label,
                                  target: self, action: #selector(sourceToggled(_:)))
            toggle.state = isEnabled(source) ? .on : .off
            toggle.font = Brand.Font.metadata
            sourceToggles[source] = toggle

            let count = NSTextField(labelWithString: countLabel(report))
            count.font = Brand.Font.metadata
            count.textColor = (report?.hosts ?? 0) > 0
                ? Brand.Color.textPrimary : Brand.Color.textSecondary

            let detail = NSTextField(labelWithString: detailLabel(source, report))
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = Brand.Color.textSecondary
            detail.lineBreakMode = .byTruncatingTail

            grid.addRow(with: [toggle, count, detail])
        }
        sourcesStack.addView(grid, in: .top)

        let importRow = NSStackView(views: [
            button("Import Hosts CSV\u{2026}", #selector(importCSV)),
            button("Create Example CSV", #selector(createExampleCSV)),
            hint("or drop a CSV anywhere on this window"),
        ])
        importRow.orientation = .horizontal
        importRow.spacing = Brand.Metric.space8
        importRow.alignment = .centerY
        sourcesStack.addView(importRow, in: .top)

        renderProfileRow()
        renderKeyRow()
    }

    /// Which AWS profile the two AWS sources authenticate with. In the card
    /// rather than only in the menubar: the window that reports a credential
    /// failure is where someone with three profiles goes to change the one tried.
    private func renderProfileRow() {
        let summaries = store.profileSummaries
        guard !summaries.isEmpty else { return }
        addSubheading("Which AWS profile")

        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.font = Brand.Font.metadata
        popup.setAccessibilityLabel("AWS profile")
        let automatic = store.activeProfileName
        popup.addItem(withTitle: automatic == nil
            ? "Automatic   environment credentials"
            : "Automatic   \(automatic ?? "")")
        popup.menu?.addItem(.separator())
        for summary in summaries {
            popup.addItem(withTitle: "\(summary.name)   \(summary.detail)")
            popup.lastItem?.representedObject = summary.name
        }
        // A profile named in the config that neither ~/.aws file carries is still
        // shown selected. Falling back to Automatic would put a lie on screen.
        if let chosen = store.config.profile,
           !summaries.contains(where: { $0.name == chosen }) {
            popup.addItem(withTitle: "\(chosen)   not in ~/.aws")
            popup.lastItem?.representedObject = chosen
        }
        popup.selectItem(at: popup.itemArray.firstIndex {
            ($0.representedObject as? String) == store.config.profile
        } ?? 0)
        popup.target = self
        popup.action = #selector(profileChosen(_:))

        let row = NSStackView(views: [popup, hint("EC2 and Systems Manager only")])
        row.orientation = .horizontal
        row.spacing = Brand.Metric.space8
        row.alignment = .centerY
        sourcesStack.addView(row, in: .top)

        let note = NSTextField(wrappingLabelWithString:
            "Read from ~/.aws/config and ~/.aws/credentials, which Hangar never "
            + "writes. Automatic follows AWS_PROFILE, then default, the same as the "
            + "aws CLI. Picking one re-checks immediately.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = Brand.Color.textSecondary
        note.preferredMaxLayoutWidth = 520
        sourcesStack.addView(note, in: .top)
    }

    @objc private func profileChosen(_ sender: NSPopUpButton) {
        let name = sender.selectedItem?.representedObject as? String
        Notifier.show(title: "AWS profile", body: store.useProfile(name), seconds: 3)
        Task { await runChecks() }
    }

    /// One more question inside the card: a rule, then a heading.
    private func addSubheading(_ text: String) {
        let divider = NSBox()
        divider.boxType = .separator
        sourcesStack.addView(divider, in: .top)
        divider.widthAnchor.constraint(equalTo: sourcesStack.widthAnchor).isActive = true

        let heading = NSTextField(labelWithString: text)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = Brand.Color.textPrimary
        sourcesStack.addView(heading, in: .top)
    }

    /// The key half of the card. Nothing at all when there is nothing to say,
    /// because a row reading "no key" teaches no one anything.
    private func renderKeyRow() {
        addSubheading("Which key ssh uses")

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Brand.Metric.space8
        row.alignment = .centerY

        if let agent = store.agents.first(where: { $0.isUsable }) {
            keyAgent = agent
            let label = NSTextField(labelWithString: "\(agent.name):")
            label.font = Brand.Font.metadata
            label.textColor = Brand.Color.textSecondary
            row.addArrangedSubview(label)

            let popup = NSPopUpButton()
            popup.addItem(withTitle: "Let ssh decide")
            for key in agent.keys { popup.addItem(withTitle: key.title) }
            let pinned = store.config.ssh?.identityFile ?? ""
            popup.selectItem(at: agent.keys.firstIndex {
                pinned.hasSuffix("/\($0.slug).pub")
            }.map { $0 + 1 } ?? 0)
            popup.target = self
            popup.action = #selector(keyChosen(_:))
            popup.controlSize = .small
            popup.font = Brand.Font.metadata
            popup.setAccessibilityLabel("SSH key")
            keyPopup = popup
            row.addArrangedSubview(popup)
        } else {
            let files = KeySource.detectKeyFiles()
            let label = NSTextField(labelWithString: files.isEmpty
                ? "No agent and no key in ~/.ssh. ssh decides for itself."
                : "In ~/.ssh: \(files.joined(separator: ", "))")
            label.font = Brand.Font.metadata
            label.textColor = Brand.Color.textSecondary
            row.addArrangedSubview(label)
        }
        row.addArrangedSubview(button("Choose\u{2026}", #selector(chooseKey)))
        sourcesStack.addView(row, in: .top)

        let note = NSTextField(wrappingLabelWithString:
            "Hangar never reads a private key. Pinning an agent key writes only "
            + "its public half, under ~/.hangar/keys, so ssh knows which one to "
            + "offer instead of trying every key in the vault.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = Brand.Color.textSecondary
        note.preferredMaxLayoutWidth = 520
        sourcesStack.addView(note, in: .top)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Brand.Font.metadata
        return button
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = Brand.Color.textSecondary
        return field
    }

    private func isEnabled(_ source: HostSource) -> Bool {
        let settings = store.config.sourceSettings
        switch source {
        case .ec2:       return settings.wantsEC2
        case .ssm:       return settings.wantsSSMAfterFailure
        case .sshConfig: return settings.wantsSSHConfig
        case .hostsFile: return settings.wantsHostsFile
        }
    }

    private func countLabel(_ report: SourceReport?) -> String {
        guard let report, report.attempted else { return "off" }
        if report.hosts > 0 { return "\(report.hosts) hosts" }
        return report.problem == nil ? "none" : "failed"
    }

    private func detailLabel(_ source: HostSource, _ report: SourceReport?) -> String {
        if let problem = report?.problem, report?.hosts == 0 {
            return String(problem.prefix(90))
        }
        // A source that read a file and used none of it owes an explanation. The
        // common case is an ssh config holding only git remotes, and "launch
        // only" next to a zero reads like Hangar could not parse it.
        if report?.hosts == 0, let skipped = report?.skipped, !skipped.isEmpty {
            let more = skipped.count > 1 ? " (+\(skipped.count - 1) more)" : ""
            return String(skipped[0].prefix(80)) + more
        }
        switch source {
        case .ec2:       return source.requirement
        case .ssm:       return "tried when EC2 is denied; needs \(source.requirement)"
        case .sshConfig: return "launch only; Hangar never rewrites this file"
        case .hostsFile: return report?.skipped.first ?? "any CSV with a header row"
        }
    }

    @objc private func sourceToggled(_ sender: NSButton) {
        guard let source = sourceToggles.first(where: { $0.value === sender })?.key else { return }
        var config = store.config
        var settings = config.sources ?? .standard
        let on = sender.state == .on
        switch source {
        case .ec2:       settings.ec2 = on
        case .ssm:       settings.ssm = on ? nil : false
        case .sshConfig: settings.sshConfig = on
        case .hostsFile: settings.hostsFile = on
        }
        config.sources = settings
        try? HangarConfig.write(config)
        store.reloadConfig()
        Task { await runChecks() }
    }

    @objc private func keyChosen(_ sender: NSPopUpButton) {
        guard let agent = keyAgent else { return }
        let index = sender.indexOfSelectedItem
        if index == 0 {
            store.clearKeyPreference()
        } else if index - 1 < agent.keys.count {
            store.adopt(agent: agent, key: agent.keys[index - 1])
        }
        Task { await runChecks() }
    }

    @objc private func chooseKey() { chooseKeyFile() }
    @objc private func importCSV() { chooseHostsFile() }

    @objc private func createExampleCSV() {
        guard store.writeExampleHostsFile() else {
            Notifier.show(title: "Could not write the example",
                          body: HangarConfig.hostsFilePath, seconds: 3)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: HangarConfig.hostsFilePath))
    }

    /// One row per idea: what it is for, and a menu of the tag keys this fleet
    /// actually has. Only shown once a fetch has produced a catalog.
    private func renderTagPicker() {
        tagsStack.subviews.forEach { $0.removeFromSuperview() }
        tagPopups = [:]

        let catalog = store.tagCatalog
        guard !catalog.isEmpty else {
            tagsCard.isHidden = true
            return
        }
        tagsCard.isHidden = false

        let title = NSTextField(labelWithString: "Which of your tags mean what")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Brand.Color.textPrimary
        tagsStack.addView(title, in: .top)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Hangar found \(catalog.keys.count) tag keys across \(catalog.fleetSize) "
            + "hosts. Point each one at the tag you use; it takes effect immediately.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Brand.Color.textSecondary
        subtitle.preferredMaxLayoutWidth = 520
        tagsStack.addView(subtitle, in: .top)

        let grid = NSGridView()
        grid.rowSpacing = Brand.Metric.space4
        grid.columnSpacing = Brand.Metric.space12

        for concept in TagCatalog.Concept.allCases {
            // Name and purpose in one cell. They were two columns and said the
            // same thing twice, which pushed the menu into a narrow middle
            // column and left the eye travelling to read one row.
            let label = NSTextField(labelWithString: concept.title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = Brand.Color.textPrimary

            let purpose = NSTextField(labelWithString: concept.explanation)
            purpose.font = .systemFont(ofSize: 10)
            purpose.textColor = Brand.Color.textSecondary

            let described = NSStackView(views: [label, purpose])
            described.orientation = .vertical
            described.alignment = .leading
            described.spacing = 0

            let popup = NSPopUpButton()
            popup.controlSize = .small
            popup.font = Brand.Font.metadata
            popup.addItem(withTitle: "Not used")
            popup.menu?.addItem(.separator())
            for key in catalog.keys {
                let sample = key.samples.prefix(2).joined(separator: ", ")
                let detail = key.distinctValues == 1
                    ? "\(key.instances) hosts, one value"
                    : "\(key.instances) hosts, \(key.distinctValues) values"
                popup.addItem(withTitle: "\(key.name)   \(detail)"
                              + (sample.isEmpty ? "" : "   \(sample)"))
                popup.lastItem?.representedObject = key.name
            }

            // Open showing what is actually in effect, or a conservative guess
            // when nothing resolves yet.
            let inEffect = store.resolvedTagKey(for: concept)
            let shown = inEffect ?? catalog.suggestion(for: concept)
            if let shown, let index = popup.itemArray.firstIndex(where: {
                ($0.representedObject as? String) == shown
            }) {
                popup.selectItem(at: index)
            } else {
                popup.selectItem(at: 0)
            }
            popup.target = self
            popup.action = #selector(tagKeyChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(concept.rawValue)
            popup.setAccessibilityLabel("\(concept.title) tag")
            tagPopups[concept] = popup

            grid.addRow(with: [described, popup])
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = Brand.Metric.space8
        tagsStack.addView(grid, in: .top)
    }

    /// The menubar cascade, as an ordered list the user composes. One level is a
    /// perfectly good answer, and so is none.
    private func renderLevels() {
        levelsStack.subviews.forEach { $0.removeFromSuperview() }
        let catalog = store.tagCatalog
        guard !catalog.isEmpty else {
            levelsCard.isHidden = true
            return
        }
        levelsCard.isHidden = false

        let title = NSTextField(labelWithString: "Menu levels")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Brand.Color.textPrimary
        levelsStack.addView(title, in: .top)

        let keys = store.groupingKeys
        let summary = NSTextField(wrappingLabelWithString: keys.isEmpty
            ? "The menu lists every host flat. Add a level to group them."
            : "Hosts nest in this order: "
              + keys.joined(separator: " \u{203A} ")
              + ". One level is enough; remove any you do not want.")
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = Brand.Color.textSecondary
        summary.preferredMaxLayoutWidth = 520
        levelsStack.addView(summary, in: .top)

        // What each level does where it actually sits. A key is not good or bad
        // on its own: env_name under product and env can be dead weight on the
        // same fleet where it reads fine on its own.
        let reports = FleetGrouping.report(store.instances, groupBy: keys)
        for (index, key) in keys.enumerated() {
            let report = index < reports.count ? reports[index]
                                              : FleetGrouping.LevelReport(key: key)
            let carried = report.groups > 0
            let label = NSTextField(labelWithString: "\(index + 1).  \(key)")
            label.font = Brand.Font.shortcut
            label.textColor = carried ? Brand.Color.textPrimary
                                      : Brand.Color.textSecondary

            let note = NSTextField(labelWithString: SetupWindow.levelNote(report))
            note.font = .systemFont(ofSize: 10)
            note.textColor = report.isMostlyEmpty ? Brand.Color.statePending
                                                  : Brand.Color.textSecondary

            let up = NSButton(title: "\u{2191}", target: self, action: #selector(moveLevelUp(_:)))
            up.tag = index
            up.isEnabled = index > 0
            let remove = NSButton(title: "Remove", target: self,
                                  action: #selector(removeLevel(_:)))
            remove.tag = index
            for button in [up, remove] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = Brand.Font.metadata
            }

            let row = NSStackView(views: [label, note, NSView(), up, remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Brand.Metric.space8
            levelsStack.addView(row, in: .top)
            row.widthAnchor.constraint(equalTo: levelsStack.widthAnchor).isActive = true
        }

        let add = NSPopUpButton()
        add.controlSize = .small
        add.font = Brand.Font.metadata
        add.addItem(withTitle: "Add a level\u{2026}")
        add.menu?.addItem(.separator())
        for entry in catalog.keys where !keys.contains(entry.name) {
            // What it would do if added, rather than what it looks like on its
            // own. The question in front of this menu is "should I add this".
            let preview = FleetGrouping.reportAppending(entry.name, to: keys,
                                                        in: store.instances)
            add.addItem(withTitle: "\(entry.name)   \(SetupWindow.levelNote(preview))")
            add.lastItem?.representedObject = entry.name
        }
        add.target = self
        add.action = #selector(addLevel(_:))
        add.isEnabled = (add.numberOfItems > 2)
        levelsStack.addView(add, in: .top)
    }

    /// One line saying what a level does. Counts, no advice: Hangar does not
    /// know that a level covering a third of the fleet is the wrong choice.
    static func levelNote(_ report: FleetGrouping.LevelReport) -> String {
        guard report.hosts > 0 else { return "no hosts" }
        guard report.groups > 0 else { return "no host carries this" }
        let groups = "\(report.groups) group" + (report.groups == 1 ? "" : "s")
        guard report.withoutValue > 0 else { return groups + ", every host tagged" }
        return groups + "  \u{00B7}  \(report.withoutValue) of \(report.hosts) "
            + "hosts have no value here"
    }

    @objc private func addLevel(_ sender: NSPopUpButton) {
        guard let key = sender.selectedItem?.representedObject as? String else { return }
        applyLevels(store.groupingKeys + [key])
    }

    @objc private func removeLevel(_ sender: NSButton) {
        var keys = store.groupingKeys
        guard keys.indices.contains(sender.tag) else { return }
        keys.remove(at: sender.tag)
        applyLevels(keys)
    }

    @objc private func moveLevelUp(_ sender: NSButton) {
        var keys = store.groupingKeys
        let index = sender.tag
        guard index > 0, keys.indices.contains(index) else { return }
        keys.swapAt(index, index - 1)
        applyLevels(keys)
    }

    private func applyLevels(_ keys: [String]) {
        let message = store.setGroupingKeys(keys)
        Notifier.show(title: "Menu levels updated", body: message, seconds: 3)
        renderLevels()
        fitToScreen()
    }

    @objc private func tagKeyChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let concept = TagCatalog.Concept(rawValue: raw) else { return }
        let key = sender.selectedItem?.representedObject as? String
        let message = store.useTagKey(key, for: concept)
        Notifier.show(title: "Tag mapping updated", body: message, seconds: 3)
        // The tagging check and the host count both depend on this.
        Task { await runChecks() }
    }

    /// The finished checks, then the one being worked on, then the ones still to
    /// come. Motion is carried by a spinner on the active step and a slow pulse on
    /// the waiting ones, so the window looks like it is discovering rather than
    /// hung, and the list never jumps: every step has a card from the first frame.
    private func renderProgress(_ done: [Preflight.Check]) {
        checksStack.subviews.forEach { $0.removeFromSuperview() }
        for check in done { add(row(for: check)) }
        for (offset, step) in SetupWindow.plan.dropFirst(done.count).enumerated() {
            add(pendingRow(title: step.title, detail: step.detail,
                           active: offset == 0, delay: Double(offset) * 0.14))
        }
    }

    private func add(_ card: NSView) {
        checksStack.addView(card, in: .top)
        card.widthAnchor.constraint(equalTo: checksStack.widthAnchor).isActive = true
    }

    /// A step that has not answered yet. Same geometry as a finished card, so
    /// nothing shifts sideways when the real one replaces it.
    private func pendingRow(title: String, detail: String,
                            active: Bool, delay: Double) -> NSView {
        let badge = NSStackView()
        badge.orientation = .vertical
        badge.alignment = .centerX
        badge.spacing = 2

        if active {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            badge.addArrangedSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: Brand.Metric.glyphSize),
                spinner.heightAnchor.constraint(equalToConstant: Brand.Metric.glyphSize),
            ])
        } else {
            let glyph = NSImageView()
            glyph.image = Brand.Glyph.symbol("circle.dotted", size: Brand.Metric.glyphSize)
            glyph.contentTintColor = Brand.Color.textSecondary
            glyph.imageScaling = .scaleProportionallyUpOrDown
            badge.addArrangedSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.widthAnchor.constraint(equalToConstant: Brand.Metric.glyphSize),
                glyph.heightAnchor.constraint(equalToConstant: Brand.Metric.glyphSize),
            ])
        }

        // The word carries the state as well as the motion does, per the brand kit.
        let status = NSTextField(labelWithString: active ? "NOW" : "WAIT")
        status.font = .systemFont(ofSize: 9, weight: .bold)
        status.textColor = Brand.Color.textSecondary
        status.alignment = .center
        badge.addArrangedSubview(status)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = active ? Brand.Color.textPrimary : Brand.Color.textSecondary
        titleField.lineBreakMode = .byTruncatingTail

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 11, weight: .regular)
        detailField.textColor = Brand.Color.textSecondary
        detailField.maximumNumberOfLines = 2
        detailField.preferredMaxLayoutWidth = 380

        let text = NSStackView(views: [titleField, detailField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let content = NSStackView(views: [badge, text])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Brand.Metric.space12
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        card.alphaValue = active ? 1 : 0.62
        card.setAccessibilityLabel("\(title), \(active ? "checking now" : "waiting")")

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 44),
            content.topAnchor.constraint(equalTo: card.topAnchor,
                                         constant: Brand.Metric.space8),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor,
                                            constant: -Brand.Metric.space8),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                             constant: Brand.Metric.space8),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                              constant: -Brand.Metric.space12),
        ])

        if !active { pulse(card, delay: delay) }
        return card
    }

    /// A slow breath on the cards still to come, staggered so the list reads as a
    /// queue rather than one block blinking. Skipped when the user has asked the
    /// system for less motion.
    private func pulse(_ view: NSView, delay: Double) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.42
        animation.toValue = 0.78
        animation.duration = 1.1
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = CACurrentMediaTime() + delay
        view.layer?.add(animation, forKey: "pulse")
    }

    private func render(_ checks: [Preflight.Check]) {
        checksStack.subviews.forEach { $0.removeFromSuperview() }
        for check in checks {
            let card = row(for: check)
            checksStack.addView(card, in: .top)
            card.widthAnchor.constraint(equalTo: checksStack.widthAnchor).isActive = true
        }
    }

    /// One check as a card: status glyph, a status word, the title, the detail, and
    /// a fix if there is one. Colour never carries the state on its own, per the
    /// brand kit, so the glyph and the word both say it.
    private func row(for check: Preflight.Check) -> NSView {
        let glyph = NSImageView()
        let word: String
        let tint: NSColor
        switch check.level {
        case .ok:
            glyph.image = Brand.Glyph.running
            tint = Brand.Color.stateRunning
            word = "OK"
        case .warning:
            glyph.image = Brand.Glyph.staleCache
            tint = Brand.Color.statePending
            word = "CHECK"
        case .problem:
            glyph.image = Brand.Glyph.stopped
            tint = Brand.Color.stateTerminated
            word = "FIX"
        }
        glyph.contentTintColor = tint
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.setAccessibilityLabel(word)

        let status = NSTextField(labelWithString: word)
        status.font = .systemFont(ofSize: 9, weight: .bold)
        status.textColor = tint
        status.alignment = .center

        let badge = NSStackView(views: [glyph, status])
        badge.orientation = .vertical
        badge.alignment = .centerX
        badge.spacing = 2

        let title = NSTextField(labelWithString: check.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Brand.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(wrappingLabelWithString: check.detail)
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = Brand.Color.textSecondary
        detail.maximumNumberOfLines = 3
        // A wrapping label needs an explicit wrap width or it lays out as one long
        // line and the row silently grows past the window.
        detail.preferredMaxLayoutWidth = 380

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        var views: [NSView] = [badge, text]
        if let remedy = check.remedy, let button = remedyButton(remedy) {
            views.append(NSView())
            views.append(button)
        }
        let content = NSStackView(views: views)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Brand.Metric.space12
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Brand.Metric.glyphSize),
            glyph.heightAnchor.constraint(equalToConstant: Brand.Metric.glyphSize),
            badge.widthAnchor.constraint(equalToConstant: 44),
            content.topAnchor.constraint(equalTo: card.topAnchor,
                                         constant: Brand.Metric.space8),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor,
                                            constant: -Brand.Metric.space8),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                             constant: Brand.Metric.space8),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                              constant: -Brand.Metric.space12),
        ])
        return card
    }

    private var pendingRemedies: [ObjectIdentifier: Preflight.Remedy] = [:]

    private func remedyButton(_ remedy: Preflight.Remedy) -> NSButton? {
        let title: String
        switch remedy {
        case .addIncludeLine:    title = "Add Include Line"
        case .openConfig:        title = "Edit Config"
        case .copyLoginCommand:  title = "Copy Login Command"
        case .openApp(_, let name): title = "Open \(name)"
        case .importHostsFile:   title = "Import Hosts CSV\u{2026}"
        }
        let button = NSButton(title: title, target: self, action: #selector(applyRemedy(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        pendingRemedies[ObjectIdentifier(button)] = remedy
        return button
    }

    @objc private func applyRemedy(_ sender: NSButton) {
        guard let remedy = pendingRemedies[ObjectIdentifier(sender)] else { return }
        switch remedy {
        case .addIncludeLine:
            do {
                try SSHConfigWriter.addIncludeLine()
                store.syncSSHConfig(announce: false)
                Notifier.show(title: "Include line added",
                              body: "~/.ssh/config now includes ~/.ssh/config.d/hangar")
            } catch {
                Notifier.show(title: "Could not edit ~/.ssh/config",
                              body: error.localizedDescription, seconds: 3)
            }
        case .copyLoginCommand(let command):
            Launcher.copyToClipboard(command)
            Notifier.show(title: "Copied", body: command)
        case .openConfig:
            NSWorkspace.shared.open(URL(fileURLWithPath: HangarConfig.path))
        case .openApp(let bundleID, let name):
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else {
                Notifier.show(title: "\(name) not found",
                              body: "Hangar could not locate \(name) on this Mac.", seconds: 3)
                break
            }
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration())
        case .importHostsFile:
            chooseHostsFile()
            return
        }
        Task { await runChecks() }
    }

    // MARK: - Hosts and keys

    /// An open panel rather than a path field. Nobody should be typing a path
    /// into a setup screen in 2026, and the only reason this exists at all is
    /// the case detection cannot cover.
    private func chooseHostsFile() {
        let panel = NSOpenPanel()
        panel.title = "Import hosts"
        panel.message = "Choose a CSV with a header row. "
            + "alias, hostname, user, port, product, env and role are understood; "
            + "any other column becomes a tag."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.importHosts(from: url) }
        }
    }

    private func importHosts(from url: URL) async {
        let message = await store.importHosts(from: url)
        Notifier.show(title: "Hosts imported", body: message, seconds: 4)
        await runChecks()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an ssh key"
        panel.message = "Pick the key ssh should use. Hangar records the path; it "
            + "never reads the key."
        panel.directoryURL = URL(fileURLWithPath:
            NSString(string: "~/.ssh").expandingTildeInPath)
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.store.adopt(keyFile: url.path)
            Task { await self.runChecks() }
        }
    }

    /// Every terminal Hangar can drive, with the ones that are not here labelled
    /// rather than hidden: "why is Ghostty not in this list" is a worse question
    /// than seeing it greyed out with the reason on it.
    private func renderTerminalPopup() {
        terminalPopup.removeAllItems()
        // Without this AppKit recomputes every item as enabled and the terminal
        // that is not on this Mac becomes a choice that quietly falls back.
        terminalPopup.menu?.autoenablesItems = false
        let installed = Launcher.installed
        for choice in TerminalChoice.allCases {
            let here = installed.contains(choice)
            terminalPopup.addItem(withTitle: choice.displayName
                                    + (here ? "" : "   not installed"))
            terminalPopup.lastItem?.representedObject = choice.rawValue
            terminalPopup.lastItem?.isEnabled = here
        }
        terminalPopup.selectItem(at: TerminalChoice.allCases
            .firstIndex(of: store.terminal) ?? 0)
    }

    @objc private func terminalChanged() {
        guard let raw = terminalPopup.selectedItem?.representedObject as? String
        else { return }
        let message = store.useTerminal(TerminalChoice.from(raw))
        Notifier.show(title: "Terminal", body: message, seconds: 3)
        // The terminal check reports what is installed and what will open, so it
        // is now out of date.
        Task { await runChecks() }
    }

    @objc private func toggleLogin() {
        let turningOn = loginToggle.state == .on
        let problem = LoginItem.set(turningOn)
        var config = store.config
        config.launchAtLogin = turningOn
        try? HangarConfig.write(config)
        store.reloadConfig()
        // The system is the source of truth: if it refused, reflect that.
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        if let problem {
            Notifier.show(title: "Login item", body: problem, seconds: 4)
        }
        closeHint.stringValue = LoginItem.statusDescription
            + " Closing this window leaves Hangar running in your menu bar."
    }

    @objc private func toggleUpdates() {
        var config = store.config
        config.checkUpdatesOnLaunch = updateToggle.state == .on
        try? HangarConfig.write(config)
        store.reloadConfig()
        channelPopup.isEnabled = updateToggle.state == .on
    }

    @objc private func channelChanged() {
        var config = store.config
        config.updateChannel = channelPopup.indexOfSelectedItem == 1 ? "beta" : "stable"
        try? HangarConfig.write(config)
        store.reloadConfig()
    }

    @objc private func toggleSync() {
        var config = store.config
        config.syncSSHConfigOnRefresh = syncToggle.state == .on
        try? HangarConfig.write(config)
        store.reloadConfig()
    }

    @objc private func openPanel() {
        HangarConfig.markOnboarded()
        window.close()
        onOpenPanel()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}


/// Top-down layout for the checks list. A plain NSView inside a scroll view lays
/// out bottom-up, which put the rows below the visible area.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Accepts a dropped file, which is how a CSV of hostnames gets in.
///
/// Only one file, and only a name that looks like a text table. Copying whatever
/// lands on the window into `~/.hangar/hosts.csv` unread would make a dropped
/// binary the fleet.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private static let extensions: Set<String> = ["csv", "tsv", "txt"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func droppedFile(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first,
              DropView.extensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedFile(sender) else { return false }
        onDrop?(url)
        return true
    }
}
