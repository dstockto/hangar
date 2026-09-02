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
    private var checksContainer: NSView!
    private var syncToggle: NSButton!
    private var loginToggle: NSButton!
    private var updateToggle: NSButton!
    private var channelPopup: NSPopUpButton!
    private var closeHint: NSTextField!
    private var openButton: NSButton!
    private var recheckButton: NSButton!
    private var running = false

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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Hangar Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        let lockup = NSImageView()
        lockup.image = Brand.Glyph.wordmark(width: 154)
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

        let disclosure = NSTextField(wrappingLabelWithString:
            "Reads ~/.aws/config, ~/.aws/credentials, the SSO token cache, and EC2 "
            + "instance tags. Writes ~/.ssh/config.d/hangar. Never reads private keys.")
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

        closeHint = NSTextField(labelWithString:
            "Closing this window leaves Hangar running in your menu bar.")
        closeHint.font = .systemFont(ofSize: 10, weight: .regular)
        closeHint.textColor = Brand.Color.textSecondary

        recheckButton = NSButton(title: "Re-check", target: self, action: #selector(recheck))
        openButton = NSButton(title: "Open Hangar", target: self, action: #selector(openPanel))
        openButton.keyEquivalent = "\r"
        let sourceButton = NSButton(title: "Source", target: self, action: #selector(openSource))
        for button in [recheckButton!, openButton!, sourceButton] {
            button.bezelStyle = .rounded
        }

        let titleBlock = NSStackView(views: [lockup, headline, body])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = Brand.Metric.space4
        titleBlock.setCustomSpacing(Brand.Metric.space8, after: lockup)

        let header = NSStackView(views: [icon, titleBlock])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = Brand.Metric.space16

        // The stack cannot be the documentView directly: a scroll view gives its
        // document no width, so every row collapses to its intrinsic size and the
        // wrapping labels render as nothing. A flipped container pinned to the clip
        // view's width fixes both the width and the top-down row order.
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        checksStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checksStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = container
        self.checksContainer = container

        NSLayoutConstraint.activate([
            checksStack.topAnchor.constraint(equalTo: container.topAnchor),
            checksStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            checksStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            checksStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let leftButtons = NSStackView(views: [sourceButton])
        leftButtons.orientation = .horizontal
        let rightButtons = NSStackView(views: [recheckButton, openButton])
        rightButtons.orientation = .horizontal
        rightButtons.spacing = Brand.Metric.space8
        let buttonRow = NSStackView(views: [leftButtons, NSView(), rightButtons])
        buttonRow.orientation = .horizontal

        let toggles = NSStackView(views: [syncToggle, loginToggle])
        toggles.orientation = .horizontal
        toggles.spacing = Brand.Metric.space24

        let updateRow = NSStackView(views: [updateToggle, channelPopup])
        updateRow.orientation = .horizontal
        updateRow.spacing = Brand.Metric.space8

        let root = NSStackView(views: [header, scroll, disclosure, toggles,
                                       updateRow, closeHint, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Brand.Metric.space12
        root.edgeInsets = NSEdgeInsets(top: Brand.Metric.space16,
                                       left: Brand.Metric.space16,
                                       bottom: Brand.Metric.space16,
                                       right: Brand.Metric.space16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            lockup.widthAnchor.constraint(equalToConstant: 154),
            lockup.heightAnchor.constraint(equalToConstant: 35),
            header.widthAnchor.constraint(equalTo: root.widthAnchor,
                                          constant: -Brand.Metric.space32),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor,
                                          constant: -Brand.Metric.space32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 392),
            disclosure.widthAnchor.constraint(equalTo: root.widthAnchor,
                                              constant: -Brand.Metric.space32),
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor,
                                             constant: -Brand.Metric.space32),
        ])
        window.contentView = content
        self.window = window
    }

    func show() {
        AppMainMenu.install()
        window.center()
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

    private func runChecks() async {
        guard !running else { return }
        running = true
        recheckButton.isEnabled = false
        headline.stringValue = "Checking your setup\u{2026}"
        render([])

        let files = AWSConfigFiles.load()
        var checks: [Preflight.Check] = [Preflight.profilesCheck(files)]

        // Refreshing is the honest credential and connectivity test: it does exactly
        // what Hangar does in normal use.
        await store.refresh()
        checks.append(Preflight.credentialsCheck(
            sourceLabel: store.credentialDescription.map { description in
                [description.label, description.literal].compactMap { $0 }.joined(separator: " ")
            },
            advice: store.credentialAdvice))

        checks.append(Preflight.taggingCheck(instances: store.instances))

        let includeFileExists = FileManager.default
            .fileExists(atPath: HangarConfig.sshIncludePath)
        checks.append(Preflight.sshIncludeCheck(
            includePresent: SSHConfigWriter.includeLinePresent(),
            fileExists: includeFileExists,
            hostCount: store.instances.count))

        let terminal = Launcher.Terminal.from(store.config.terminal)
        checks.append(Preflight.terminalCheck(
            configured: store.config.terminal,
            installed: terminal.isInstalled,
            fallbackInstalled: Launcher.Terminal.terminal.isInstalled))

        checks.append(Preflight.hotkeyCheck(problem: hotkeyProblem(),
                                            combination: hotkeyCombination()))

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
        recheckButton.isEnabled = true
        running = false
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
        }
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

    @objc private func openSource() {
        NSWorkspace.shared.open(Updates.repoURL)
    }
}


/// Top-down layout for the checks list. A plain NSView inside a scroll view lays
/// out bottom-up, which put the rows below the visible area.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
