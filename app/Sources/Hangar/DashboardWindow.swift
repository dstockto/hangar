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
    private var footer: NSTextField!
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

        footer = NSTextField(labelWithString: "")
        footer.font = Brand.Font.metadata
        footer.textColor = Brand.Color.textSecondary
        footer.translatesAutoresizingMaskIntoConstraints = false

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
        tabs.segmentStyle = .automatic
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
        content.addSubview(footer)
        content.addSubview(refresh)
        window.contentView = content

        NSLayoutConstraint.activate([
            cluster.topAnchor.constraint(equalTo: content.topAnchor),
            cluster.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cluster.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cluster.bottomAnchor.constraint(equalTo: footer.topAnchor,
                                            constant: -Brand.Metric.space8),

            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor,
                                           constant: -Brand.Metric.space8),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            panels.topAnchor.constraint(equalTo: document.topAnchor,
                                        constant: Brand.Metric.space16),
            panels.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                            constant: Brand.Metric.space16),
            panels.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                             constant: -Brand.Metric.space16),
            panels.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                           constant: -Brand.Metric.space16),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                            constant: Brand.Metric.space16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                           constant: -Brand.Metric.space12),
            refresh.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                              constant: -Brand.Metric.space16),
            refresh.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
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
        panels.addArrangedSubview(statStrip(insights))
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

        var parts = [count(insights.total, "host"), "\(insights.running) running"]
        if insights.stopped > 0 { parts.append("\(insights.stopped) stopped") }
        if !store.region.isEmpty { parts.append(store.region) }
        if let age = store.cacheAgeDescription { parts.append(age) }
        footer.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: - Panels

    /// "1 host" and "2 hosts", never "1 host(s)".
    private func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }

    private func hygienePanel(_ insights: FleetInsights) -> NSView {
        let hygiene = insights.hygiene
        var rows: [(RowKind, String, String)] = []
        if hygiene.missingProduct > 0 {
            rows.append((.warn, "No product tag", "\(hygiene.missingProduct) hosts"))
        }
        if hygiene.missingEnv > 0 {
            rows.append((.warn, "No env tag", "\(hygiene.missingEnv) hosts"))
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
            rows.append((.warn, "\(group.product) · \(group.env) is only in \(group.zones.first ?? "?")",
                         "\(group.count) hosts"))
        }
        if singleZone.count > 6 {
            rows.append((.note, "and \(singleZone.count - 6) more in one zone", ""))
        }
        for group in insights.placement.sorted(by: { $0.pets > $1.pets }).prefix(3)
        where group.pets > 0 {
            rows.append((.note, "\(group.product) · \(group.env) outside an autoscaling group",
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
                (bucket.label == "over 180 days" ? .warn : .note,
                 "Up \(bucket.label)", "\(bucket.count) hosts")
            }
        let flagged = insights.families.filter { $0.isPreviousGeneration || $0.isBurstable }
        for family in flagged.prefix(5) {
            let note = [family.isPreviousGeneration ? "previous generation" : nil,
                        family.isBurstable ? "burstable" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            rows.append((.note, "\(family.family), \(note)", "\(family.count) hosts"))
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
            rows.append((.warn, "Public address in \(env.env)",
                         "\(env.withPublicAddress) of \(env.total)"))
        }
        if insights.exposure.allSatisfy({ $0.withPublicAddress == 0 }) {
            rows.append((.ok, "No host carries a public address", ""))
        }
        return panel(title: "Change and exposure", symbol: "chart.line.uptrend.xyaxis",
                     headline: count(history.count, "refresh", "refreshes") + " recorded",
                     rows: rows)
    }

    /// Four numbers across the top, each in its own tile. The strip is the part
    /// someone reads without reading: a glyph, a count, a noun.
    private func statStrip(_ insights: FleetInsights) -> NSView {
        let tiles: [(String, String, String, NSColor)] = [
            ("shippingbox", "\(insights.total)",
             insights.total == 1 ? "host" : "hosts", Brand.Color.textPrimary),
            ("play.circle", "\(insights.running)", "running", Brand.Color.stateRunning),
            ("stop.circle", "\(insights.stopped)", "stopped", Brand.Color.stateStopped),
            ("square.grid.2x2", "\(insights.placement.count)",
             insights.placement.count == 1 ? "group" : "groups", Brand.Color.accent),
        ]
        let views = tiles.map { symbol, value, caption, tint -> NSView in
            let glyph = NSImageView()
            glyph.image = Brand.Glyph.symbol(symbol, size: 15)
            glyph.contentTintColor = tint
            let number = NSTextField(labelWithString: value)
            number.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            number.textColor = Brand.Color.textPrimary
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = Brand.Color.textSecondary
            let text = NSStackView(views: [number, label])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            let row = NSStackView(views: [glyph, text])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Brand.Metric.space8
            return card(row)
        }
        let strip = NSStackView(views: views)
        strip.orientation = .horizontal
        strip.distribution = .fillEqually
        strip.spacing = Brand.Metric.space8
        return strip
    }

    /// The card chrome in one place, so every tile and panel matches.
    private func card(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Brand.Color.textPrimary.withAlphaComponent(0.06).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor,
                                         constant: Brand.Metric.space12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor,
                                            constant: -Brand.Metric.space12),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                             constant: Brand.Metric.space12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                              constant: -Brand.Metric.space12),
        ])
        return card
    }

    /// A row's glyph says what kind of line it is before the words do.
    enum RowKind {
        case ok, warn, note

        var symbol: String {
            switch self {
            case .ok:   return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .note: return "circle.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .ok:   return Brand.Color.stateRunning
            case .warn: return Brand.Color.statePending
            case .note: return Brand.Color.textSecondary
            }
        }
    }

    /// One card: a glyph, a heading, the number that matters, and the rows.
    private func panel(title: String, symbol: String, headline: String,
                       rows: [(RowKind, String, String)]) -> NSView {
        let glyph = NSImageView()
        glyph.image = Brand.Glyph.symbol(symbol, size: 14)
        glyph.contentTintColor = Brand.Color.accent
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = Brand.Color.textSecondary
        let headingRow = NSStackView(views: [glyph, heading])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 6

        let number = NSTextField(labelWithString: headline)
        number.font = .systemFont(ofSize: 16, weight: .semibold)
        number.textColor = Brand.Color.textPrimary

        let stack = NSStackView(views: [headingRow, number])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(Brand.Metric.space8, after: number)

        for (kind, left, right) in rows {
            let bullet = NSImageView()
            bullet.image = Brand.Glyph.symbol(kind.symbol, size: kind == .note ? 7 : 11)
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
