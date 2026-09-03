import AppKit
import Combine
import HangarCore

/// What the fleet says about itself, from the response Hangar already fetched.
///
/// A separate window from the setup screen on purpose: setup is a readiness
/// check someone reads once, this is a question asked again and again. Every
/// number comes from `FleetInsights`, which is computed and tested in the core;
/// nothing here needs a second AWS call.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    private let store: FleetStore
    private var window: NSWindow!
    private var cluster: ClusterView!
    private var panels: NSStackView!
    private var tabs: NSSegmentedControl!
    private var scroll: NSScrollView!
    private var sidebar: NSStackView!
    private var cards: NSStackView!
    private var observers: [AnyCancellable] = []

    private static let frameName = "HangarDashboardWindow"

    init(store: FleetStore) {
        self.store = store
        super.init()
        build()
        store.$instances.sink { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }.store(in: &observers)
    }

    func show() {
        reload()
        switchTab()
        if !window.isVisible { AppMainMenu.install() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The menu bar belongs to whatever windows are open, so it goes when this
    /// one does. Closing never ends the app: Hangar carries on in the menu bar.
    func windowWillClose(_ notification: Notification) {
        AppMainMenu.release()
    }

    // MARK: - Construction

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 940),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Hangar Fleet"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 680, height: 600)
        // Restored first, then autosaved: setting the autosave name alone does
        // not put a closed window back where it was on the next launch.
        if !window.setFrameUsingName(DashboardWindow.frameName) { window.center() }
        window.setFrameAutosaveName(DashboardWindow.frameName)

        cluster = ClusterView(frame: .zero)
        cluster.translatesAutoresizingMaskIntoConstraints = false
        // Opening a group narrows the panels to it, so the numbers always
        // describe whatever the picture is currently showing.
        cluster.onFocusChange = { [weak self] hosts, focus in
            Task { @MainActor in self?.renderPanels(for: hosts, focus: focus) }
        }

        panels = NSStackView()
        panels.orientation = .vertical
        panels.alignment = .leading
        panels.spacing = Brand.Metric.space12
        panels.translatesAutoresizingMaskIntoConstraints = false

        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(panels)
        scroll.documentView = document

        cards = NSStackView()
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.distribution = .fillEqually
        cards.spacing = Brand.Metric.space8
        // Low hugging, so this is the part of the column that takes the slack.
        cards.setContentHuggingPriority(.init(1), for: .vertical)

        sidebar = NSStackView(views: [cards])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.distribution = .fill
        sidebar.spacing = Brand.Metric.space8
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let refresh = NSButton(title: "Refresh Fleet", target: self,
                               action: #selector(refreshFleet))
        refresh.bezelStyle = .rounded
        refresh.translatesAutoresizingMaskIntoConstraints = false

        // A segmented control in the title bar, rather than a tab strip in the
        // content: the fleet page is a picture, and a picture wants the window.
        tabs = NSSegmentedControl(labels: ["Fleet", "Insights"],
                                  trackingMode: .selectOne,
                                  target: self, action: #selector(switchTab))
        tabs.selectedSegment = 0
        let accessory = NSTitlebarAccessoryViewController()
        let holder = NSView()
        holder.addSubview(tabs)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabs.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            tabs.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
            tabs.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -8),
            holder.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        accessory.view = holder
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)

        let content = NSView()
        content.addSubview(cluster)
        content.addSubview(scroll)
        // Added last, so the pages can never draw over the numbers.
        content.addSubview(sidebar)
        content.addSubview(refresh)
        window.contentView = content

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor,
                                         constant: Brand.Metric.space16),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                             constant: Brand.Metric.space16),
            sidebar.widthAnchor.constraint(equalToConstant: 214),
            sidebar.bottomAnchor.constraint(equalTo: refresh.topAnchor,
                                            constant: -Brand.Metric.space12),
            cards.widthAnchor.constraint(equalTo: sidebar.widthAnchor),

            refresh.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            refresh.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            refresh.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                            constant: -Brand.Metric.space16),

            cluster.topAnchor.constraint(equalTo: content.topAnchor),
            cluster.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                             constant: Brand.Metric.space16),
            cluster.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cluster.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: content.topAnchor,
                                        constant: Brand.Metric.space16),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                            constant: Brand.Metric.space16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                           constant: -Brand.Metric.space16),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            panels.topAnchor.constraint(equalTo: document.topAnchor),
            panels.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            panels.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                             constant: -Brand.Metric.space16),
            panels.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                           constant: -Brand.Metric.space16),
        ])
    }

    /// The picture and the numbers are the same data; only one of them is on
    /// screen at a time so neither has to be cramped.
    @objc private func switchTab() {
        let showingFleet = tabs.selectedSegment == 0
        cluster.isHidden = !showingFleet
        scroll.isHidden = showingFleet
        // The picture is keyboard navigable, so it takes the keyboard when it is
        // the thing on screen. Without this the arrows do nothing until someone
        // finds it with Tab, which needs Full Keyboard Access turned on.
        if showingFleet { window.makeFirstResponder(cluster) }
    }

    @objc private func refreshFleet() {
        Task { @MainActor in await store.refresh() }
    }

    // MARK: - Content

    private func reload() {
        // The panels are drawn from the cluster's focus callback, which showing
        // it always fires. Rendering them here as well would describe the whole
        // fleet for as long as it took that callback to land.
        cluster.show(store.instances, groupBy: store.config.groupingKeys,
                     region: store.region)
    }

    private func renderPanels(for hosts: [Instance], focus: ClusterFocus) {
        let insights = FleetInsights.compute(hosts)

        panels.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Below the fleet, this tab is the only thing on screen, so it carries
        // its own way out. The hub does the same job on the Fleet tab, and it
        // is not on this one.
        if let destination = focus.backDestination {
            panels.addArrangedSubview(backButton(to: destination))
        }
        // One host open: show its record instead of fleet statistics about a
        // sample of one. Everything on it came from the same DescribeInstances
        // response; there is no second call behind this screen.
        if hosts.count == 1, let host = hosts.first {
            for panel in [hostPanel(host), hostTagsPanel(host)] {
                panels.addArrangedSubview(panel)
                panel.widthAnchor.constraint(equalTo: panels.widthAnchor).isActive = true
            }
            renderSidebar(insights, scope: focus.label)
            return
        }
        for panel in [hygienePanel(insights), placementPanel(insights),
                      agePanel(insights), deltaPanel(insights)] {
            panels.addArrangedSubview(panel)
            panel.widthAnchor.constraint(equalTo: panels.widthAnchor).isActive = true
        }

        renderSidebar(insights, scope: focus.label)
    }

    /// Named after where it goes rather than labelled "Back", so it says what
    /// leaving this screen actually lands on.
    private func backButton(to destination: String) -> NSButton {
        let button = NSButton(title: ClusterView.backTitle(to: destination),
                              target: self, action: #selector(stepOut))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = Brand.Glyph.symbol("chevron.left", size: 10)
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func stepOut() {
        cluster.stepOut()
    }

    /// The facts, as cards down the side rather than a line of grey text along
    /// the bottom. Each one is a label, a number, and a colour that belongs to
    /// what it counts.
    /// `scope` is what the numbers are about: empty for the whole fleet, the
    /// focus label below it. The cards are focus-scoped, so their notes have to
    /// be too, or a single open host reads "100% of the fleet".
    private func renderSidebar(_ insights: FleetInsights, scope: String) {
        cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in sidebar.arrangedSubviews where view !== cards {
            view.removeFromSuperview()
        }

        let tiles: [(String, String, String, String, NSColor)] = [
            ("shippingbox", "Total hosts", "\(insights.total)",
             store.region.isEmpty ? "" : store.region, Brand.Color.accent),
            ("play.circle", "Running", "\(insights.running)",
             insights.total > 0
                ? "\(Int((Double(insights.running) / Double(insights.total)) * 100))% of "
                    + (scope.isEmpty ? "the fleet" : scope)
                : "", Brand.Color.stateRunning),
            ("stop.circle", "Stopped", "\(insights.stopped)",
             insights.stopped == 0 ? "nothing parked" : "still billing for storage",
             Brand.Color.stateStopped),
            ("square.grid.2x2", "Groups", "\(insights.placement.count)",
             "\(insights.hygiene.isClean ? "tags clean" : "tags need a look")",
             Brand.Color.statePending),
        ]
        for (symbol, label, value, note, tint) in tiles {
            let card = statCard(symbol: symbol, label: label, value: value,
                                note: note, tint: tint)
            cards.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }

        let rail = StateRail()
        rail.set(running: insights.running, stopped: insights.stopped,
                 other: max(0, insights.total - insights.running - insights.stopped))
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.heightAnchor.constraint(equalToConstant: 8).isActive = true
        sidebar.addArrangedSubview(rail)

        let cache = NSTextField(labelWithString: store.cacheAgeDescription ?? "no cache yet")
        cache.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cache.textColor = Brand.Color.textSecondary
        sidebar.addArrangedSubview(cache)

        for view in sidebar.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        // The number grows with the card, so a tall column does not leave four
        // small numbers stranded at the top of four large boxes.
        for card in cards.arrangedSubviews {
            card.setContentHuggingPriority(.init(1), for: .vertical)
        }
    }

    /// One sidebar card: a coloured rail, a tracked label, a big monospaced
    /// number, and a note that says what the number means.
    private func statCard(symbol: String, label: String, value: String,
                          note: String, tint: NSColor) -> NSView {
        let glyph = NSImageView()
        glyph.image = Brand.Glyph.symbol(symbol, size: 12)
        glyph.contentTintColor = tint
        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = NSAttributedString(
            string: label.uppercased(),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                         .foregroundColor: Brand.Color.textSecondary, .kern: 1.4])
        let head = NSStackView(views: [glyph, title])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 5

        let number = NSTextField(labelWithString: value)
        number.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        number.textColor = Brand.Color.textPrimary

        var views: [NSView] = [head, number]
        if !note.isEmpty {
            let caption = NSTextField(labelWithString: note)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = Brand.Color.textSecondary
            caption.lineBreakMode = .byTruncatingTail
            views.append(caption)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1

        // The rail is part of the row rather than pinned over the card, because
        // a second leading constraint on the same stack collapsed the card.
        let rail = NSView()
        rail.wantsLayer = true
        rail.layer?.backgroundColor = tint.withAlphaComponent(0.9).cgColor
        rail.layer?.cornerRadius = 1.5
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let row = NSStackView(views: [rail, stack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Brand.Metric.space8
        rail.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        return card(row)
    }

    /// "1 host" and "2 hosts", never "1 host(s)".
    private func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }

    private func hygienePanel(_ insights: FleetInsights) -> NSView {
        let hygiene = insights.hygiene
        var rows: [PanelRow] = []
        if hygiene.missingProduct > 0 {
            rows.append(PanelRow(.tag, "No product tag", count(hygiene.missingProduct, "host")))
        }
        if hygiene.missingEnv > 0 {
            rows.append(PanelRow(.tag, "No env tag", count(hygiene.missingEnv, "host")))
        }
        if hygiene.missingName > 0 {
            rows.append(PanelRow(.warn, "No name tag, alias falls back to the instance id",
                         count(hygiene.missingName, "host")))
        }
        if hygiene.missingHostname > 0 {
            rows.append(PanelRow(.note, "No hostname tag, reached by private address",
                         count(hygiene.missingHostname, "host")))
        }
        // Reported, not flagged: Hangar numbers these and ssh reaches the right
        // host either way. The number is what moves when an instance is
        // replaced, which is the part worth knowing.
        let shared = hygiene.sharedNames.sorted { $0.key < $1.key }
        for (name, count) in shared.prefix(6) {
            rows.append(PanelRow(.note, "\(name) numbered \(name)-1 … \(name)-\(count)",
                         self.count(count, "host")))
        }
        if shared.count > 6 {
            rows.append(PanelRow(.note, "and \(shared.count - 6) more names Hangar numbers", ""))
        }
        if hygiene.isClean {
            rows.insert(PanelRow(.ok, "Every host has the tags Hangar maps", ""), at: 0)
        }
        return panel(title: "Tag hygiene", symbol: "tag",
                     headline: hygiene.isClean
                        ? (shared.isEmpty ? "Clean"
                           : "Clean  ·  " + count(shared.count, "name") + " Hangar numbers")
                        : count(hygiene.problems, "thing") + " to fix",
                     rows: rows)
    }

    private func placementPanel(_ insights: FleetInsights) -> NSView {
        let singleZone = insights.placement.filter(\.isSingleZone)
        let pets = insights.placement.reduce(0) { $0 + $1.pets }
        var rows: [PanelRow] = []
        for group in singleZone.prefix(6) {
            rows.append(PanelRow(.zone, "\(group.product) · \(group.env) is only in \(group.zones.first ?? "?")",
                         count(group.count, "host")))
        }
        if singleZone.count > 6 {
            rows.append(PanelRow(.note, "and \(singleZone.count - 6) more in one zone", ""))
        }
        for group in insights.placement.sorted(by: { $0.pets > $1.pets }).prefix(3)
        where group.pets > 0 {
            rows.append(PanelRow(.scaling, "\(group.product) · \(group.env) outside an autoscaling group",
                         "\(group.pets) of \(group.count)"))
        }
        if rows.isEmpty {
            rows.append(PanelRow(.ok, "Every group spans more than one zone", ""))
        }
        return panel(title: "Placement and autoscaling",
                     symbol: "point.3.connected.trianglepath.dotted",
                     headline: count(singleZone.count, "single-zone group") + "  ·  "
                             + count(pets, "host") + " outside an autoscaling group",
                     rows: rows)
    }

    private func agePanel(_ insights: FleetInsights) -> NSView {
        var rows: [PanelRow] = insights.ages
            .filter { $0.count > 0 }
            .map { bucket in
                PanelRow(bucket.label == "over 180 days" ? .warn : .clock,
                         "Up \(bucket.label)", count(bucket.count, "host"))
            }
        let flagged = insights.families.filter { $0.isPreviousGeneration || $0.isBurstable }
        for family in flagged.prefix(5) {
            let note = [family.isPreviousGeneration ? "previous generation" : nil,
                        family.isBurstable ? "burstable" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            rows.append(PanelRow(.family, "\(family.family), \(note)", count(family.count, "host")))
        }
        let old = insights.ages.first { $0.label == "over 180 days" }?.count ?? 0
        return panel(title: "Age and instance families", symbol: "clock.arrow.circlepath",
                     headline: old == 0 ? "Nothing up longer than 180 days"
                                        : count(old, "host") + " up over 180 days",
                     rows: rows)
    }

    private func deltaPanel(_ insights: FleetInsights) -> NSView {
        var rows: [PanelRow] = []
        let history = store.history
        if history.count >= 2, let last = history.last {
            let previous = history[history.count - 2]
            let change = last.hosts - previous.hosts
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let word = change == 0 ? "no change" : (change > 0 ? "+\(change)" : "\(change)")
            rows.append(PanelRow(change == 0 ? .note : .warn,
                         "Since \(formatter.string(from: previous.at)): \(previous.hosts) to \(last.hosts)",
                         word))
        } else {
            rows.append(PanelRow(.note, "No history yet, the delta needs a second refresh", ""))
        }
        for env in insights.exposure where env.withPublicAddress > 0 {
            rows.append(PanelRow(.address, "Public address in \(env.env)",
                         "\(env.withPublicAddress) of \(env.total)"))
        }
        if insights.exposure.allSatisfy({ $0.withPublicAddress == 0 }) {
            rows.append(PanelRow(.ok, "No host carries a public address", ""))
        }
        return panel(title: "Change and exposure", symbol: "chart.line.uptrend.xyaxis",
                     headline: count(history.count, "refresh", "refreshes") + " recorded",
                     rows: rows)
    }

    /// Everything DescribeInstances said about one host, which is more than
    /// Hangar has ever shown and costs nothing extra to show.
    private func hostPanel(_ host: Instance) -> NSView {
        let alias = store.alias(for: host) ?? host.aliasStem
        // The rows someone opens a host to read are led: what it is, how big,
        // where it is, and what to type to reach it. The rest is reference.
        var rows: [PanelRow] = [
            PanelRow(host.state == "running" ? .ok : .note, "State",
                     host.stateReason.map { "\(host.state) · \($0)" } ?? host.state,
                     lead: true),
            PanelRow(.clock, "Launched", launchDescription(host)),
            PanelRow(.family, "Instance type", typeDescription(host), lead: true),
            PanelRow(.note, "Instance id", host.id),
            PanelRow(.zone, "Availability zone", host.availabilityZone ?? "unknown"),
        ]
        if let vpc = host.vpcID { rows.append(PanelRow(.zone, "VPC", vpc)) }
        if let subnet = host.subnetID { rows.append(PanelRow(.zone, "Subnet", subnet)) }
        rows.append(PanelRow(.note, "Private address", host.privateIP ?? "none", lead: true))
        if let dns = host.privateDNS, !dns.isEmpty {
            rows.append(PanelRow(.note, "Private DNS", dns))
        }
        if let publicIP = host.publicIP, !publicIP.isEmpty {
            rows.append(PanelRow(.address, "Public address", publicIP))
        }
        if let hostname = host.tags["hostname"], !hostname.isEmpty {
            rows.append(PanelRow(.note, "Hostname tag", hostname))
        }
        if let image = host.imageID { rows.append(PanelRow(.note, "AMI", image)) }
        if let key = host.keyName, !key.isEmpty {
            rows.append(PanelRow(.note, "Key pair", key))
        }
        if let profile = host.iamProfile, !profile.isEmpty {
            rows.append(PanelRow(.note, "IAM instance profile", profile))
        }
        if let groups = host.securityGroups, !groups.isEmpty {
            rows.append(PanelRow(.address, "Security groups", groups.joined(separator: ", ")))
        }
        if let lifecycle = host.lifecycle, !lifecycle.isEmpty {
            // Worth knowing before you ssh in and start work on it.
            rows.append(PanelRow(.warn, "Lifecycle", lifecycle))
        }
        if let monitoring = host.monitoring, !monitoring.isEmpty {
            rows.append(PanelRow(.note, "Monitoring", monitoring))
        }
        if let root = host.rootDeviceType { rows.append(PanelRow(.note, "Root device", root)) }
        rows.append(PanelRow(.scaling, "Autoscaling group",
                     host.isASG ? host.asg : "none, this one is a pet"))
        rows.append(PanelRow(.note, "ssh alias", alias, lead: true))
        return panel(title: "Host", symbol: "shippingbox", headline: alias, rows: rows)
    }

    /// The type, plus what the response said it contains and runs.
    private func typeDescription(_ host: Instance) -> String {
        var parts = [host.type]
        if let vcpus = host.vcpus { parts.append("\(vcpus) vCPU") }
        if let architecture = host.architecture { parts.append(architecture) }
        if let platform = host.platform, platform.lowercased() != "linux/unix" {
            parts.append(platform)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Every tag, because the one you need is always the one a summary dropped.
    private func hostTagsPanel(_ host: Instance) -> NSView {
        let rows: [PanelRow] = host.tags.keys.sorted().map { key in
            PanelRow(.tag, key, host.tags[key] ?? "")
        }
        return panel(title: "Tags", symbol: "tag",
                     headline: count(rows.count, "tag"),
                     rows: rows.isEmpty ? [PanelRow(.note, "This instance carries no tags", "")]
                                        : rows)
    }

    /// "3 days ago, 14 August" beats a raw ISO timestamp for the question people
    /// actually ask, which is how long this box has been up.
    private func launchDescription(_ host: Instance) -> String {
        guard let launched = ISO8601DateFormatter().date(from: host.launchTime) else {
            return host.launchTime.isEmpty ? "unknown" : host.launchTime
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let absolute = DateFormatter()
        absolute.dateFormat = "d MMMM yyyy"
        return "\(relative.localizedString(for: launched, relativeTo: Date())), "
            + absolute.string(from: launched)
    }

    /// The card chrome in one place, so every tile and panel matches.
    private func card(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        // Depth from the border, never a shadow: a wall of cards stays calm.
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Brand.Color.textPrimary.withAlphaComponent(0.08).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor,
                                         constant: Brand.Metric.space16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor,
                                            constant: -Brand.Metric.space16),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                             constant: Brand.Metric.space16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                              constant: -Brand.Metric.space16),
        ])
        return card
    }

    /// A row's glyph says what kind of line it is before the words do.
    /// One line in a panel. `lead` marks the rows someone opened the panel to
    /// read, so they are not drawn at the same weight as "Root device".
    struct PanelRow {
        var kind: RowKind
        var label: String
        var value: String
        var lead: Bool

        init(_ kind: RowKind, _ label: String, _ value: String, lead: Bool = false) {
            self.kind = kind
            self.label = label
            self.value = value
            self.lead = lead
        }
    }

    enum RowKind {
        case ok, warn, note
        /// The subject of the row, when it has one worth a glyph: a zone, an
        /// autoscaling group, an instance family, an address. Severity still
        /// decides the colour, so the shape says what and the colour says how
        /// worried to be.
        case zone, scaling, family, clock, address, tag

        var symbol: String {
            switch self {
            case .ok:      return "checkmark.circle.fill"
            case .warn:    return "exclamationmark.triangle.fill"
            case .note:    return "circle.fill"
            case .zone:    return "globe.americas.fill"
            case .scaling: return "arrow.triangle.2.circlepath"
            case .family:  return "cpu"
            case .clock:   return "clock"
            case .address: return "network"
            case .tag:     return "tag"
            }
        }

        var tint: NSColor {
            switch self {
            case .ok:                        return Brand.Color.stateRunning
            case .warn, .zone, .address:     return Brand.Color.statePending
            case .note, .scaling, .family, .clock, .tag:
                                             return Brand.Color.textSecondary
            }
        }

        var glyphSize: CGFloat { self == .note ? 7 : 12 }
    }

    /// One card: a glyph, a heading, the number that matters, and the rows.
    private func panel(title: String, symbol: String, headline: String,
                       rows: [PanelRow]) -> NSView {
        let glyph = NSImageView()
        glyph.image = Brand.Glyph.symbol(symbol, size: 14)
        glyph.contentTintColor = Brand.Color.accent
        let heading = NSTextField(labelWithString: "")
        heading.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                         .foregroundColor: Brand.Color.textSecondary,
                         .kern: 1.4])
        let headingRow = NSStackView(views: [glyph, heading])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 6

        let number = NSTextField(labelWithString: headline)
        number.font = .systemFont(ofSize: 16, weight: .semibold)
        number.textColor = Brand.Color.textPrimary
        number.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [headingRow, number])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(Brand.Metric.space8, after: number)

        for entry in rows {
            let bullet = NSImageView()
            bullet.image = Brand.Glyph.symbol(entry.kind.symbol, size: entry.kind.glyphSize)
            bullet.contentTintColor = entry.kind.tint

            let label = NSTextField(labelWithString: entry.label)
            label.font = .systemFont(ofSize: 12,
                                     weight: entry.lead ? .medium : .regular)
            label.textColor = entry.lead ? Brand.Color.textPrimary
                                         : Brand.Color.textSecondary
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            // A led row's value is the thing on the screen worth copying, so it
            // gets the weight and the foreground colour; the rest is reference
            // and reads as reference.
            let detail = NSTextField(labelWithString: entry.value)
            detail.font = .monospacedDigitSystemFont(ofSize: entry.lead ? 12 : 11,
                                                     weight: entry.lead ? .semibold : .regular)
            detail.textColor = entry.lead ? Brand.Color.textPrimary
                                          : Brand.Color.textSecondary
            detail.alignment = .right
            detail.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let row = NSStackView(views: [bullet, label, NSView(), detail])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Brand.Metric.space8
            bullet.widthAnchor.constraint(equalToConstant: 12).isActive = true
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card(stack)
    }
}

/// The fleet's state as one bar: running, stopped, everything else. A shape
/// beside the numbers rather than instead of them, and every segment is also a
/// count in the tiles above it, so colour is never carrying this alone.
@MainActor
final class StateRail: NSView {
    private var segments: [(count: Int, colour: NSColor)] = []
    private var total = 0

    func set(running: Int, stopped: Int, other: Int) {
        segments = [(running, Brand.Color.stateRunning),
                    (stopped, Brand.Color.stateStopped),
                    (other, Brand.Color.statePending)]
        total = running + stopped + other
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        Brand.Color.textPrimary.withAlphaComponent(0.08).setFill()
        track.fill()
        guard total > 0 else { return }

        var x: CGFloat = 0
        for segment in segments where segment.count > 0 {
            // A real but tiny share still gets a sliver: rounding it away would
            // say a stopped host does not exist.
            let width = max(bounds.height * 0.7,
                            bounds.width * CGFloat(segment.count) / CGFloat(total))
            let rect = NSRect(x: x, y: 0, width: min(width, bounds.width - x),
                              height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            segment.colour.withAlphaComponent(0.85).setFill()
            path.fill()
            x += rect.width + 1
            if x >= bounds.width { break }
        }
    }
}
