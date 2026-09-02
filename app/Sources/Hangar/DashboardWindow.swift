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
        cluster.onFocusChange = { [weak self] hosts, label in
            Task { @MainActor in self?.renderPanels(for: hosts, focus: label) }
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

        sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
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

            refresh.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            refresh.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            refresh.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                            constant: -Brand.Metric.space16),
            refresh.topAnchor.constraint(greaterThanOrEqualTo: sidebar.bottomAnchor,
                                         constant: Brand.Metric.space12),

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
    }

    @objc private func refreshFleet() {
        Task { @MainActor in await store.refresh() }
    }

    // MARK: - Content

    private func reload() {
        cluster.show(store.instances, groupBy: store.config.groupingKeys,
                     region: store.region)
        renderPanels(for: store.instances, focus: "")
    }

    private func renderPanels(for hosts: [Instance], focus: String) {
        let insights = FleetInsights.compute(hosts)

        panels.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !focus.isEmpty {
            let scope = NSTextField(labelWithString:
                "Showing \(focus). Click the centre circle to go back to the fleet.")
            scope.font = .systemFont(ofSize: 11, weight: .medium)
            scope.textColor = Brand.Color.accent
            panels.addArrangedSubview(scope)
        }
        for panel in [hygienePanel(insights), placementPanel(insights),
                      agePanel(insights), deltaPanel(insights)] {
            panels.addArrangedSubview(panel)
            panel.widthAnchor.constraint(equalTo: panels.widthAnchor).isActive = true
        }

        renderSidebar(insights)
    }

    /// The facts, as cards down the side rather than a line of grey text along
    /// the bottom. Each one is a label, a number, and a colour that belongs to
    /// what it counts.
    private func renderSidebar(_ insights: FleetInsights) {
        sidebar.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let cards: [(String, String, String, String, NSColor)] = [
            ("shippingbox", "Total hosts", "\(insights.total)",
             store.region.isEmpty ? "" : store.region, Brand.Color.accent),
            ("play.circle", "Running", "\(insights.running)",
             insights.total > 0
                ? "\(Int((Double(insights.running) / Double(insights.total)) * 100))% of the fleet"
                : "", Brand.Color.stateRunning),
            ("stop.circle", "Stopped", "\(insights.stopped)",
             insights.stopped == 0 ? "nothing parked" : "still billing for storage",
             Brand.Color.stateStopped),
            ("square.grid.2x2", "Groups", "\(insights.placement.count)",
             "\(insights.hygiene.isClean ? "tags clean" : "tags need a look")",
             Brand.Color.statePending),
        ]
        for (symbol, label, value, note, tint) in cards {
            sidebar.addArrangedSubview(statCard(symbol: symbol, label: label,
                                                value: value, note: note, tint: tint))
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
        var rows: [(RowKind, String, String)] = []
        if hygiene.missingProduct > 0 {
            rows.append((.tag, "No product tag", "\(hygiene.missingProduct) hosts"))
        }
        if hygiene.missingEnv > 0 {
            rows.append((.tag, "No env tag", "\(hygiene.missingEnv) hosts"))
        }
        if hygiene.missingName > 0 {
            rows.append((.warn, "No name tag, alias falls back to the instance id",
                         "\(hygiene.missingName) hosts"))
        }
        if hygiene.missingHostname > 0 {
            rows.append((.note, "No hostname tag, reached by private address",
                         "\(hygiene.missingHostname) hosts"))
        }
        for (alias, count) in hygiene.duplicateAliases.sorted(by: { $0.key < $1.key }) {
            rows.append((.warn, "Alias \(alias) is shared", "\(count) hosts"))
        }
        if rows.isEmpty {
            rows.append((.ok, "Every host has the tags Hangar maps", ""))
        }
        return panel(title: "Tag hygiene", symbol: "tag",
                     headline: hygiene.isClean ? "Clean"
                                               : count(rows.count, "thing") + " to fix",
                     rows: rows)
    }

    private func placementPanel(_ insights: FleetInsights) -> NSView {
        let singleZone = insights.placement.filter(\.isSingleZone)
        let pets = insights.placement.reduce(0) { $0 + $1.pets }
        var rows: [(RowKind, String, String)] = []
        for group in singleZone.prefix(6) {
            rows.append((.zone, "\(group.product) · \(group.env) is only in \(group.zones.first ?? "?")",
                         "\(group.count) hosts"))
        }
        if singleZone.count > 6 {
            rows.append((.note, "and \(singleZone.count - 6) more in one zone", ""))
        }
        for group in insights.placement.sorted(by: { $0.pets > $1.pets }).prefix(3)
        where group.pets > 0 {
            rows.append((.scaling, "\(group.product) · \(group.env) outside an autoscaling group",
                         "\(group.pets) of \(group.count)"))
        }
        if rows.isEmpty {
            rows.append((.ok, "Every group spans more than one zone", ""))
        }
        return panel(title: "Placement and autoscaling",
                     symbol: "point.3.connected.trianglepath.dotted",
                     headline: count(singleZone.count, "single-zone group") + "  ·  "
                             + count(pets, "host") + " outside an autoscaling group",
                     rows: rows)
    }

    private func agePanel(_ insights: FleetInsights) -> NSView {
        var rows: [(RowKind, String, String)] = insights.ages
            .filter { $0.count > 0 }
            .map { bucket in
                (bucket.label == "over 180 days" ? .warn : .clock,
                 "Up \(bucket.label)", "\(bucket.count) hosts")
            }
        let flagged = insights.families.filter { $0.isPreviousGeneration || $0.isBurstable }
        for family in flagged.prefix(5) {
            let note = [family.isPreviousGeneration ? "previous generation" : nil,
                        family.isBurstable ? "burstable" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            rows.append((.family, "\(family.family), \(note)", "\(family.count) hosts"))
        }
        let old = insights.ages.first { $0.label == "over 180 days" }?.count ?? 0
        return panel(title: "Age and instance families", symbol: "clock.arrow.circlepath",
                     headline: old == 0 ? "Nothing up longer than 180 days"
                                        : count(old, "host") + " up over 180 days",
                     rows: rows)
    }

    private func deltaPanel(_ insights: FleetInsights) -> NSView {
        var rows: [(RowKind, String, String)] = []
        let history = store.history
        if history.count >= 2, let last = history.last {
            let previous = history[history.count - 2]
            let change = last.hosts - previous.hosts
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let word = change == 0 ? "no change" : (change > 0 ? "+\(change)" : "\(change)")
            rows.append((change == 0 ? .note : .warn,
                         "Since \(formatter.string(from: previous.at)): \(previous.hosts) to \(last.hosts)",
                         word))
        } else {
            rows.append((.note, "No history yet, the delta needs a second refresh", ""))
        }
        for env in insights.exposure where env.withPublicAddress > 0 {
            rows.append((.address, "Public address in \(env.env)",
                         "\(env.withPublicAddress) of \(env.total)"))
        }
        if insights.exposure.allSatisfy({ $0.withPublicAddress == 0 }) {
            rows.append((.ok, "No host carries a public address", ""))
        }
        return panel(title: "Change and exposure", symbol: "chart.line.uptrend.xyaxis",
                     headline: count(history.count, "refresh", "refreshes") + " recorded",
                     rows: rows)
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
                       rows: [(RowKind, String, String)]) -> NSView {
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

        for (kind, left, right) in rows {
            let bullet = NSImageView()
            bullet.image = Brand.Glyph.symbol(kind.symbol, size: kind.glyphSize)
            bullet.contentTintColor = kind.tint

            let label = NSTextField(labelWithString: left)
            label.font = .systemFont(ofSize: 12)
            label.textColor = Brand.Color.textPrimary
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let detail = NSTextField(labelWithString: right)
            detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detail.textColor = Brand.Color.textSecondary
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
