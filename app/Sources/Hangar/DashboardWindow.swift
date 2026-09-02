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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Hangar Fleet"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 520)
        // Restored first, then autosaved: setting the autosave name alone does
        // not put a closed window back where it was on the next launch.
        if !window.setFrameUsingName(DashboardWindow.frameName) { window.center() }
        window.setFrameAutosaveName(DashboardWindow.frameName)

        cluster = ClusterView(frame: .zero)
        cluster.translatesAutoresizingMaskIntoConstraints = false

        panels = NSStackView()
        panels.orientation = .vertical
        panels.alignment = .leading
        panels.spacing = Brand.Metric.space12
        panels.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
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
            cluster.heightAnchor.constraint(equalTo: content.heightAnchor,
                                            multiplier: 0.36),

            scroll.topAnchor.constraint(equalTo: cluster.bottomAnchor),
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

    @objc private func refreshFleet() {
        Task { @MainActor in await store.refresh() }
    }

    // MARK: - Content

    private func reload() {
        let insights = FleetInsights.compute(store.instances)
        cluster.show(store.instances, groupBy: store.config.groupingKeys,
                     region: store.region)

        panels.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for panel in [hygienePanel(insights), placementPanel(insights),
                      agePanel(insights), deltaPanel(insights)] {
            panels.addArrangedSubview(panel)
            panel.widthAnchor.constraint(equalTo: panels.widthAnchor).isActive = true
        }

        var parts = ["\(insights.total) hosts", "\(insights.running) running"]
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
        var rows: [(String, String)] = []
        if hygiene.missingProduct > 0 {
            rows.append(("\(hygiene.missingProduct) hosts have no product tag",
                         "they group under untagged and get id-shaped aliases"))
        }
        if hygiene.missingEnv > 0 {
            rows.append(("\(hygiene.missingEnv) hosts have no env tag",
                         "nothing marks them as production or not"))
        }
        if hygiene.missingName > 0 {
            rows.append(("\(hygiene.missingName) hosts have no name tag",
                         "their alias falls back to the instance id"))
        }
        if hygiene.missingHostname > 0 {
            rows.append(("\(hygiene.missingHostname) hosts have no hostname tag",
                         "Hangar connects to their private address instead"))
        }
        for (alias, count) in hygiene.duplicateAliases.sorted(by: { $0.key < $1.key }) {
            rows.append(("\(count) hosts share the alias \(alias)",
                         "ssh reaches whichever entry it reads first"))
        }
        if rows.isEmpty {
            rows.append(("Every host has the tags Hangar maps",
                         "aliases are unambiguous and reach a hostname"))
        }
        return panel(title: "Tag hygiene",
                     headline: hygiene.isClean ? "Clean"
                                               : count(rows.count, "thing") + " to fix",
                     rows: rows)
    }

    private func placementPanel(_ insights: FleetInsights) -> NSView {
        let singleZone = insights.placement.filter(\.isSingleZone)
        let pets = insights.placement.reduce(0) { $0 + $1.pets }
        var rows: [(String, String)] = []
        for group in singleZone.prefix(6) {
            rows.append(("\(group.product) · \(group.env) is in one zone",
                         "\(group.count) hosts, all in \(group.zones.first ?? "?")"))
        }
        if singleZone.count > 6 {
            rows.append(("and \(singleZone.count - 6) more in one zone", ""))
        }
        for group in insights.placement.sorted(by: { $0.pets > $1.pets }).prefix(3)
        where group.pets > 0 {
            rows.append(("\(group.product) · \(group.env) has \(group.pets) hosts outside an autoscaling group",
                         "\(group.inAutoscalingGroup) of \(group.count) are in one"))
        }
        if rows.isEmpty {
            rows.append(("Every group spans more than one zone", ""))
        }
        return panel(title: "Placement and autoscaling",
                     headline: count(singleZone.count, "single-zone group") + "  ·  "
                             + count(pets, "host") + " outside an autoscaling group",
                     rows: rows)
    }

    private func agePanel(_ insights: FleetInsights) -> NSView {
        var rows = insights.ages.filter { $0.count > 0 }
            .map { ("\($0.count) hosts \($0.label)", "") }
        let flagged = insights.families.filter { $0.isPreviousGeneration || $0.isBurstable }
        for family in flagged.prefix(5) {
            let note = [family.isPreviousGeneration ? "previous generation" : nil,
                        family.isBurstable ? "burstable" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            rows.append(("\(family.count) hosts on \(family.family)", note))
        }
        let old = insights.ages.first { $0.label == "over 180 days" }?.count ?? 0
        return panel(title: "Age and instance families",
                     headline: old == 0 ? "Nothing up longer than 180 days"
                                        : count(old, "host") + " up over 180 days",
                     rows: rows)
    }

    private func deltaPanel(_ insights: FleetInsights) -> NSView {
        var rows: [(String, String)] = []
        let history = store.history
        if history.count >= 2, let last = history.last {
            let previous = history[history.count - 2]
            let change = last.hosts - previous.hosts
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let word = change == 0 ? "unchanged" : (change > 0 ? "+\(change)" : "\(change)")
            rows.append(("\(previous.hosts) to \(last.hosts) since \(formatter.string(from: previous.at))",
                         word))
        } else {
            rows.append(("No history yet", "the delta appears after a second refresh"))
        }
        for env in insights.exposure where env.withPublicAddress > 0 {
            rows.append(("\(env.withPublicAddress) of \(env.total) hosts in \(env.env) have a public address", ""))
        }
        if insights.exposure.allSatisfy({ $0.withPublicAddress == 0 }) {
            rows.append(("No host carries a public address", ""))
        }
        return panel(title: "Change and exposure",
                     headline: count(history.count, "refresh", "refreshes") + " recorded",
                     rows: rows)
    }

    /// One card: a heading, the number that matters, and the rows behind it.
    private func panel(title: String, headline: String,
                       rows: [(String, String)]) -> NSView {
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = Brand.Color.textSecondary

        let number = NSTextField(labelWithString: headline)
        number.font = .systemFont(ofSize: 15, weight: .semibold)
        number.textColor = Brand.Color.textPrimary

        let stack = NSStackView(views: [heading, number])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        for (left, right) in rows {
            let label = NSTextField(labelWithString: left)
            label.font = .systemFont(ofSize: 12)
            label.textColor = Brand.Color.textPrimary
            label.lineBreakMode = .byTruncatingTail
            let detail = NSTextField(labelWithString: right)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = Brand.Color.textSecondary
            let row = NSStackView(views: [label, detail])
            row.orientation = .horizontal
            row.spacing = Brand.Metric.space8
            stack.addArrangedSubview(row)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Brand.Color.surfaceRaised.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor,
                                       constant: Brand.Metric.space12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor,
                                          constant: -Brand.Metric.space12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                           constant: Brand.Metric.space12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                            constant: -Brand.Metric.space12),
        ])
        return card
    }
}
