import AppKit
import HangarCore

/// The fleet as a settling cluster: one node per product, one per environment
/// inside it, and every host a particle on a ring around its environment.
///
/// Gource animates history, which Hangar does not have on first launch, so this
/// animates structure instead. Product and environment nodes find their own
/// places with a small force simulation and then stop, because a picture that
/// never stops moving is a picture nobody reads. Hosts are not simulated: a
/// force solve over three thousand bodies would spend the whole frame budget
/// saying only which environment each host belongs to, which a ring says for
/// free and says the same way every launch.
@MainActor
final class ClusterView: NSView {

    private struct Node {
        var label: String
        var product: String
        var env: String?
        var count: Int
        var running: Int
        var stopped: Int
        var other: Int
        var position: CGPoint
        var radius: CGFloat
        /// How far out this node sits, from its environment's distance from
        /// production. The varying lengths are the depth in the picture.
        var tier: Int = 0
        /// Set by the layout: the drawn radius after any shrink to fit, the
        /// angle from the hub, and the slice of the ring this node owns.
        var drawRadius: CGFloat = 0
        var angle: CGFloat = 0
        var slice: CGFloat = 0
        /// Distance from the hub, set by the tier.
        var band: CGFloat = 0
        /// Set when the node is a single host, so it can be coloured by state
        /// and opened for its metadata.
        var state: String?
        var instanceID: String?
        /// The instance type, for the tooltip: the circle says how big, this
        /// says exactly which.
        var type: String?
        /// `4xl`, `lg`: what fits inside a host circle.
        var shortSize: String?
        /// The second line of the tooltip: a hostname, or nothing for a group.
        var detail: String?
        /// Hosts drawn around this node, at angles fixed by their instance id so
        /// the same host lands in the same place on every refresh.
        var hostAngles: [(angle: CGFloat, state: String)] = []
    }

    /// Clicking a circle goes in, clicking the hub goes back out, which is the
    /// whole navigation model. The filtering itself lives in the core.
    private var instances: [Instance] = []
    private var groupingKeys: [String] = []
    private var focus: ClusterFocus = .fleet
    /// Called with whatever is now in view, so the panels below can describe the
    /// same subset the picture does.
    var onFocusChange: (([Instance], String) -> Void)?

    private var nodes: [Node] = []
    /// Every group hangs off one hub: the account's EC2 inventory, which is the
    /// single call all of this came from. It also gives the layout something to
    /// orbit, so the picture reads as one fleet rather than scattered blobs.
    private var hubLabel = "EC2"
    private var hubTotal = 0
    private var timer: Timer?
    private var hostLevel = false
    private var entrance: CGFloat = 1
    private var ringRadius: CGFloat = 0
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    /// How many groups get a name drawn. Beyond this the ring is more label than
    /// picture; the hovered node is always named on top of these.
    private var labelBudget: Int {
        // At host level every circle is named: the name is the whole point of
        // the row, and they are short enough to fit around the ring.
        hostLevel ? nodes.count : max(6, Int(min(bounds.width, bounds.height) / 46))
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Stopped when the window goes away rather than in deinit: a timer holding
    /// the view keeps it alive, and deinit cannot touch main-actor state anyway.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            solveLayout()
        }
    }

    // MARK: - Content

    private var region = ""

    func show(_ instances: [Instance], groupBy keys: [String], region: String = "") {
        self.instances = instances
        self.groupingKeys = keys
        self.region = region
        if !focus.isFleet, !instances.contains(where: { inFocus($0) }) {
            // What was open went away between refreshes; do not strand the view.
            focus = .fleet
        }
        rebuild()
    }

    private func inFocus(_ instance: Instance) -> Bool {
        focus.matches(instance, groupingKeys: groupingKeys)
    }

    private func rebuild() {
        let visible = instances.filter { inFocus($0) }
        // A level still to descend means circles are groups; past the last one,
        // or with a single host open, they are hosts.
        if focus.hostID == nil, focus.nextKey(groupingKeys) != nil, visible.count > 1 {
            buildGroups(visible)
        } else {
            buildHosts(visible)
        }
        onFocusChange?(visible, focusLabel)
    }

    private var focusLabel: String { focus.label }

    /// One circle per host, for a group that has been opened.
    private func buildHosts(_ members: [Instance]) {
        hubTotal = members.count
        hubLabel = focusLabel.isEmpty ? "EC2" : "\(focusLabel)  ·  back"
        hostLevel = true
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        nodes = members.enumerated().map { index, instance in
            let angle = CGFloat(index) / CGFloat(max(1, members.count)) * .pi * 2
            let alias = instance.leafLabel(alias: instance.aliasStem,
                                           groupedBy: groupingKeys)
            return Node(label: alias, product: instance.product,
                        env: instance.env, count: 1,
                        running: instance.state == "running" ? 1 : 0,
                        stopped: instance.state == "stopped" ? 1 : 0,
                        other: 0,
                        position: CGPoint(x: centre.x + cos(angle) * 150,
                                          y: centre.y + sin(angle) * 120),
                        // At host level the circle is the machine's size, so a
                        // 4xlarge next to a medium reads as one at a glance.
                        radius: min(46, 9 + sqrt(InstanceType(instance.type).sizeWeight) * 5),
                        state: instance.state,
                        instanceID: instance.id,
                        type: instance.type,
                        shortSize: InstanceType(instance.type).shortSize,
                        detail: instance.host ?? instance.id,
                        hostAngles: [])
        }
        setAccessibilityLabel("\(focusLabel): \(members.count) hosts.")
        refreshAccessibilityChildren()
        restart()
    }

    private func buildGroups(_ instances: [Instance]) {
        hostLevel = false
        hubTotal = instances.count
        hubLabel = region.isEmpty ? "EC2" : "EC2 · \(region)"
        // The level being shown is the next one down the configured cascade, so
        // the picture drills the same way the menubar menu does: product, then
        // environment, then the hosts themselves.
        let levelKey = focus.nextKey(groupingKeys) ?? TagMapping.Canonical.product
        var byGroup: [String: [Instance]] = [:]
        for instance in instances {
            byGroup[value(instance, levelKey), default: []].append(instance)
        }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // Sorted by tier first, so each band forms an arc rather than being
        // scattered around the ring, then by name so the order never changes
        // between refreshes.
        // Sorted by how close to production the value reads, then by name, so
        // each band forms an arc and the order never changes between refreshes.
        let ordered = byGroup.keys.sorted { left, right in
            let leftTier = EnvironmentTier.of(left), rightTier = EnvironmentTier.of(right)
            if leftTier != rightTier { return leftTier.rawValue < rightTier.rawValue }
            return left < right
        }
        nodes = ordered.enumerated().map { index, key in
            let members = byGroup[key] ?? []
            // Seeded on a circle rather than at random: the same fleet settles
            // into the same picture, which is what makes it comparable.
            let angle = CGFloat(index) / CGFloat(max(1, ordered.count)) * .pi * 2
            let seed = CGPoint(x: centre.x + cos(angle) * 140,
                               y: centre.y + sin(angle) * 110)
            let running = members.count { $0.state == "running" }
            let stopped = members.count { $0.state == "stopped" }
            return Node(
                label: key.isEmpty ? "untagged" : key,
                product: key.isEmpty ? "untagged" : key,
                env: nil,
                count: members.count, running: running, stopped: stopped,
                other: members.count - running - stopped,
                position: seed,
                // Area with the host count, so a group twice the size looks
                // twice the size. Floored so a single host is still clickable
                // and capped so one huge group cannot eat the view.
                radius: min(52, 9 + sqrt(CGFloat(members.count)) * 6),
                // Distance from the hub: production innermost, each tier a step
                // further out. That is where the varying lengths come from.
                tier: EnvironmentTier.of(key).rawValue,
                hostAngles: members.map { instance in
                    (angle: CGFloat(ClusterView.hash(instance.id) % 3600) / 3600 * .pi * 2,
                     state: instance.state)
                })
        }

        setAccessibilityLabel(accessibilitySummary())
        refreshAccessibilityChildren()
        restart()
    }

    private func value(_ instance: Instance, _ key: String) -> String {
        let resolved = instance.tagValue(for: key)
        return resolved.isEmpty ? "" : resolved
    }

    /// Stable across launches, unlike `hashValue`, which is seeded per process.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x100000001b3
        }
        return value
    }

    // MARK: - Layout

    /// Groups sit on one ring around the hub, each given an angular slice wide
    /// enough for its own circle plus a gap. Solved rather than simulated: a
    /// force layout drifted, overlapped at two dozen groups, and drew a
    /// different picture every launch. This one cannot overlap, and the same
    /// fleet lands in the same place every time.
    private func solveLayout() {
        guard !nodes.isEmpty else { needsDisplay = true; return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let usable = min(bounds.width, bounds.height) / 2
        let outer = max(96, usable - (nodes.map(\.radius).max() ?? 20) - 34)
        // Production sits nearest the hub and each tier steps outward, which is
        // where the varying lengths come from. Only the tiers actually present
        // get a band, so a fleet with one environment is still a clean ring.
        let tiers = Set(nodes.map(\.tier)).sorted()
        let inner = tiers.count > 1 ? max(76, outer * 0.62) : outer
        let step = tiers.count > 1 ? (outer - inner) / CGFloat(tiers.count - 1) : 0
        let bandOf = Dictionary(uniqueKeysWithValues: tiers.enumerated().map {
            ($0.element, inner + step * CGFloat($0.offset))
        })

        // Angles are solved against the innermost band, so a node that sits
        // further out has more room than it needs rather than less. That is what
        // keeps varying lengths from reintroducing overlap.
        var scale: CGFloat = 1
        for _ in 0..<14 {
            let needed = nodes.reduce(CGFloat(0)) { total, node in
                total + 2 * asin(min(0.9, (node.radius * scale + 9) / inner))
            }
            if needed <= .pi * 2 { break }
            scale *= 0.9
        }

        let slices = nodes.map { node in
            2 * asin(min(0.9, (node.radius * scale + 9) / inner))
        }
        let leftover = max(0, (.pi * 2) - slices.reduce(0, +))
        let share = leftover / CGFloat(nodes.count)
        var angle: CGFloat = -.pi / 2
        for index in nodes.indices {
            let slice = slices[index] + share
            let mid = angle + slice / 2
            let band = bandOf[nodes[index].tier] ?? outer
            nodes[index].drawRadius = nodes[index].radius * scale
            nodes[index].angle = mid
            nodes[index].slice = slice
            nodes[index].band = band
            nodes[index].position = CGPoint(x: centre.x + cos(mid) * band,
                                            y: centre.y + sin(mid) * band)
            angle += slice
        }
        ringRadius = outer
        needsDisplay = true
    }

    /// The one piece of motion left: everything slides out from the hub once,
    /// then holds. Nothing drifts afterwards.
    private func restart() {
        timer?.invalidate()
        timer = nil
        solveLayout()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            entrance = 1
            needsDisplay = true
            return
        }
        entrance = 0
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let window = self.window, window.isVisible else { return }
                let t = min(1, Date().timeIntervalSince(started) / 0.55)
                // Ease out, so it arrives rather than stops.
                self.entrance = CGFloat(1 - pow(1 - t, 3))
                self.needsDisplay = true
                if t >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
    }

    override func layout() {
        super.layout()
        solveLayout()
    }

    /// How far this node's host dots reach beyond its own circle, so a label
    /// can be placed past them rather than through them.
    private func hostReach(_ node: Node) -> CGFloat {
        guard !node.hostAngles.isEmpty else { return 0 }
        let usable = min(max(0.04, node.slice - 0.06), 0.44)
        let perArc = max(1, min(node.hostAngles.count, Int(usable * node.band / 9)))
        let arcs = Int(ceil(Double(node.hostAngles.count) / Double(perArc)))
        return 9 + CGFloat(max(0, arcs - 1)) * 7 + 4
    }

    /// Where a node is right now, which during the entrance is somewhere between
    /// the hub and its solved place on the ring.
    private func drawPosition(_ node: Node) -> CGPoint {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let reach = node.band * entrance
        return CGPoint(x: centre.x + cos(node.angle) * reach,
                       y: centre.y + sin(node.angle) * reach)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Brand.Color.panel.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if nodes.isEmpty {
            let text = "No hosts to draw yet."
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: Brand.Color.textSecondary,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                                y: bounds.midY - size.height / 2),
                                    withAttributes: attributes)
            return
        }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let hubRadius: CGFloat = 40

        // Spokes first, so every circle sits on top of its own line. They run
        // straight out from the hub along each group's own angle, so a spoke
        // cannot cross another circle.
        for node in nodes {
            let tint = node.state.map { Brand.Color.state(for: $0) }
                ?? Brand.Color.category(for: node.product)
            context.setStrokeColor(tint.withAlphaComponent(0.35).cgColor)
            let unit = CGVector(dx: cos(node.angle), dy: sin(node.angle))
            let reach = node.band * entrance
            // Trimmed at both ends so the line touches neither circle.
            let from = CGPoint(x: centre.x + unit.dx * (hubRadius + 3),
                               y: centre.y + unit.dy * (hubRadius + 3))
            let to = CGPoint(x: centre.x + unit.dx * (reach - node.drawRadius - 3),
                             y: centre.y + unit.dy * (reach - node.drawRadius - 3))
            guard reach > hubRadius + node.drawRadius + 8 else { continue }
            // Weight carries the same fact as the circle's size, quietly.
            context.setLineWidth(max(0.6, min(2.4, sqrt(CGFloat(node.count)) * 0.5)))
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }

        // Hosts, batched by state so a ring of them is a few fills rather than
        // one per host. Each host sits inside its own group's slice of the ring,
        // measured from the hub, which is what makes overlap impossible rather
        // than merely unlikely.
        for state in ["running", "stopped", "pending", "terminated"] {
            let colour = Brand.Color.state(for: state)
            context.setFillColor(colour.withAlphaComponent(0.9).cgColor)
            let path = CGMutablePath()
            for node in nodes {
                let members = node.hostAngles.filter { $0.state == state }
                guard !members.isEmpty else { continue }
                let all = node.hostAngles.count
                // Capped as well as bounded by the slice: with six products on
                // the ring each slice is sixty degrees, and a halo spread that
                // wide stopped reading as a halo and became a second circle.
                let usable = min(max(0.04, node.slice - 0.06), 0.44)
                for host in members {
                    guard let position = node.hostAngles.firstIndex(where: {
                        $0.angle == host.angle && $0.state == host.state
                    }) else { continue }
                    // Two arcs when one would crowd, both inside the wedge.
                    let perArc = max(1, min(all, Int(usable * node.band / 9)))
                    let arc = position / perArc
                    let withinArc = position % perArc
                    let countInArc = min(perArc, all - arc * perArc)
                    let spread = countInArc == 1 ? 0
                        : usable * (CGFloat(withinArc) / CGFloat(countInArc - 1) - 0.5)
                    let angle = node.angle + spread
                    let distance = node.band + node.drawRadius + 9 + CGFloat(arc) * 7
                    let point = CGPoint(x: centre.x + cos(angle) * distance * entrance,
                                        y: centre.y + sin(angle) * distance * entrance)
                    path.addEllipse(in: CGRect(x: point.x - 2.4, y: point.y - 2.4,
                                               width: 4.8, height: 4.8))
                }
            }
            context.addPath(path)
            context.fillPath()
        }

        for (index, node) in nodes.enumerated() {
            let drawn = drawPosition(node)
            let rect = CGRect(x: drawn.x - node.drawRadius, y: drawn.y - node.drawRadius,
                              width: node.drawRadius * 2, height: node.drawRadius * 2)
            // A host is coloured by its state, a group by its product. Neither
            // colour is load bearing: the count sits inside every group circle,
            // the name is on it or one hover away, and the panels below say the
            // same things in words.
            let tint = node.state.map { Brand.Color.state(for: $0) }
                ?? Brand.Color.category(for: node.product)
            context.setFillColor(tint.withAlphaComponent(index == hovered ? 0.38 : 0.24).cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(tint.withAlphaComponent(index == hovered ? 1 : 0.8).cgColor)
            context.setLineWidth(index == hovered ? 2.5 : 1.5)
            context.strokeEllipse(in: rect)

            // A host circle shows how big the machine is; a group shows how
            // many. An empty circle after drilling in was a wasted one.
            let label = node.state == nil
                ? "\(node.count)"
                : (node.drawRadius >= 13 ? (node.shortSize ?? "") : "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: node.state == nil ? 13 : min(12, max(9, node.drawRadius * 0.5)),
                    weight: .semibold),
                .foregroundColor: Brand.Color.textPrimary,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: drawn.x - size.width / 2,
                                                 y: drawn.y - size.height / 2),
                                     withAttributes: attributes)

        }

        // The hub, drawn over the spokes and under the labels.
        let hubRect = CGRect(x: centre.x - hubRadius, y: centre.y - hubRadius,
                             width: hubRadius * 2, height: hubRadius * 2)
        context.setFillColor(Brand.Color.panel.cgColor)
        context.fillEllipse(in: hubRect)
        context.setStrokeColor(Brand.Color.accent.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: hubRect)

        let total = "\(hubTotal)"
        let totalAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: Brand.Color.textPrimary,
        ]
        let totalSize = (total as NSString).size(withAttributes: totalAttributes)
        (total as NSString).draw(at: CGPoint(x: centre.x - totalSize.width / 2,
                                             y: centre.y - totalSize.height / 2 - 6),
                                 withAttributes: totalAttributes)
        let hostsWord: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Brand.Color.textSecondary,
        ]
        let word = hubTotal == 1 ? "host" : "hosts"
        let wordSize = (word as NSString).size(withAttributes: hostsWord)
        (word as NSString).draw(at: CGPoint(x: centre.x - wordSize.width / 2,
                                            y: centre.y + 8),
                                withAttributes: hostsWord)

        let hubName = hubLabel
        let hubAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Brand.Color.textSecondary,
        ]
        let hubSize = (hubName as NSString).size(withAttributes: hubAttributes)
        (hubName as NSString).draw(at: CGPoint(x: centre.x - hubSize.width / 2,
                                               y: centre.y + hubRadius + 8),
                                   withAttributes: hubAttributes)

        // Group labels last, and on a pill: drawn inline they ended up underneath
        // the next node's circle, which is when a label is least readable.
        //
        // Only the biggest groups are named. Two dozen labels on one ring
        // overlap into noise, and the rest are one hover away, which is the
        // honest trade: the count is inside every circle either way.
        let named = Set(nodes.indices
            .sorted { nodes[$0].count > nodes[$1].count }
            .prefix(labelBudget))
        for (index, node) in nodes.enumerated() where named.contains(index) || index == hovered {
            let name = node.label
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: index == hovered ? Brand.Color.textPrimary
                                                   : Brand.Color.textSecondary,
            ]
            let size = (name as NSString).size(withAttributes: attributes)
            // Pushed out past this node's hosts, then pushed out again until it
            // clears every other circle. A label sitting on a neighbour is the
            // one thing a ring of them cannot survive.
            var outward = node.band * entrance + node.drawRadius
                + hostReach(node) + 14 + size.height / 2
            var origin = CGPoint.zero
            var pill = CGRect.zero
            for _ in 0..<8 {
                let anchor = CGPoint(x: centre.x + cos(node.angle) * outward,
                                     y: centre.y + sin(node.angle) * outward)
                origin = CGPoint(x: anchor.x - size.width / 2,
                                 y: anchor.y - size.height / 2)
                pill = CGRect(x: origin.x - 5, y: origin.y - 2,
                              width: size.width + 10, height: size.height + 4)
                let clash = nodes.contains { other in
                    let drawn = drawPosition(other)
                    let circle = CGRect(x: drawn.x - other.drawRadius - 3,
                                        y: drawn.y - other.drawRadius - 3,
                                        width: other.drawRadius * 2 + 6,
                                        height: other.drawRadius * 2 + 6)
                    return circle.intersects(pill)
                }
                if !clash { break }
                outward += size.height + 4
            }
            context.setFillColor(Brand.Color.panel.withAlphaComponent(0.82).cgColor)
            context.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5,
                                   transform: nil))
            context.fillPath()
            (name as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = nodes.firstIndex { node in
            let drawn = drawPosition(node)
            return hypot(drawn.x - point.x, drawn.y - point.y) <= node.drawRadius + 8
        }
        guard found != hovered else { return }
        hovered = found
        toolTip = found.map { index in
            let node = nodes[index]
            if let state = node.state {
                return "\(node.label)\n\(node.detail ?? "")\n\(node.type ?? "")  ·  \(state)"
            }
            return "\(node.label): \(node.count) hosts, \(node.running) running, "
                + "\(node.stopped) stopped\nClick to open"
        }
        needsDisplay = true
    }

    /// A click into an inactive window normally only activates it. Here the
    /// first click should also drill in: the circle is what the person aimed at.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        if hypot(point.x - centre.x, point.y - centre.y) <= 42 {
            guard !focus.isFleet else { return }
            focus = focus.leaving()
            rebuild()
            return
        }
        guard let index = nodes.firstIndex(where: { node in
            let drawn = drawPosition(node)
            return hypot(drawn.x - point.x, drawn.y - point.y) <= node.drawRadius
        }) else { return }
        // A group opens one level down; a host opens itself, which is where the
        // metadata appears.
        open(index)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        toolTip = nil
        needsDisplay = true
    }

    // MARK: - Accessibility
    //
    // Each circle is a button in the accessibility tree, so the cluster can be
    // driven without a mouse and read without sight. It also means the picture
    // can be tested by pressing its elements rather than by clicking pixels,
    // which is the only reliable way when another window is in front.

    private func refreshAccessibilityChildren() {
        ClusterActions.clear()
        let children: [Any] = nodes.enumerated().map { index, node in
            let element = ClusterNodeElement { [weak self] in self?.open(index) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            let described = node.state == nil
                ? "\(node.label), \(node.count) hosts"
                : "\(node.label), \(node.type ?? ""), \(node.state ?? "")"
            element.setAccessibilityLabel(described)
            element.setAccessibilityTitle(node.label)
            let drawn = drawPosition(node)
            let rect = NSRect(x: drawn.x - node.drawRadius, y: drawn.y - node.drawRadius,
                              width: node.drawRadius * 2, height: node.drawRadius * 2)
            element.setAccessibilityFrameInParentSpace(rect)
            return element
        } + [hubElement()]
        setAccessibilityChildren(children)
    }

    private func hubElement() -> NSAccessibilityElement {
        let element = ClusterNodeElement { [weak self] in
            guard let self, !self.focus.isFleet else { return }
            self.focus = self.focus.leaving()
            self.rebuild()
        }
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.button)
        let title = focus.isFleet
            ? "\(hubTotal) hosts in the fleet"
            : "Back to \(focus.leaving().label.isEmpty ? "the fleet" : focus.leaving().label)"
        element.setAccessibilityLabel(title)
        element.setAccessibilityTitle(title)
        element.setAccessibilityFrameInParentSpace(
            NSRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80))
        return element
    }

    /// Opening a circle: a group descends a level, a host opens its record.
    private func open(_ index: Int) {
        guard nodes.indices.contains(index) else { return }
        if let id = nodes[index].instanceID {
            focus = focus.opening(host: id)
        } else {
            focus = focus.entering(nodes[index].product == "untagged" ? "" : nodes[index].product)
        }
        hovered = nil
        rebuild()
    }

    private func accessibilitySummary() -> String {
        let hosts = nodes.reduce(0) { $0 + $1.count }
        let running = nodes.reduce(0) { $0 + $1.running }
        return "Fleet cluster: \(hosts) hosts in \(nodes.count) groups, \(running) running. "
            + "The panels below say the same in text."
    }
}


/// One circle, as something the accessibility tree can press.
///
/// The press arrives on a nonisolated path, so the element carries a token
/// rather than a closure: an Int can cross to the main actor, a closure over
/// main-actor state cannot, and this module does not sign `@unchecked
/// Sendable` waivers to pretend otherwise.
@MainActor
final class ClusterNodeElement: NSAccessibilityElement {
    /// Immutable, so the nonisolated press can read it without a waiver.
    private let token: Int

    init(onPress: @escaping () -> Void) {
        token = ClusterActions.register(onPress)
        super.init()
    }

    override nonisolated func accessibilityPerformPress() -> Bool {
        let token = self.token
        Task { @MainActor in ClusterActions.action(for: token)?() }
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override nonisolated func isAccessibilityElement() -> Bool { true }
}

/// Where the circles' actions live, so an element can refer to one by number.
@MainActor
enum ClusterActions {
    private static var actions: [Int: () -> Void] = [:]
    private static var counter = 0

    static func register(_ action: @escaping () -> Void) -> Int {
        counter += 1
        actions[counter] = action
        return counter
    }

    static func action(for token: Int) -> (() -> Void)? { actions[token] }

    /// Called when the cluster rebuilds, so the table cannot grow forever.
    static func clear() {
        actions.removeAll()
    }
}
