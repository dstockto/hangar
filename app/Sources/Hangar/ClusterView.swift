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
        var velocity: CGVector = .zero
        var radius: CGFloat
        /// Hosts drawn around this node, at angles fixed by their instance id so
        /// the same host lands in the same place on every refresh.
        var hostAngles: [(angle: CGFloat, state: String)] = []
    }

    private var nodes: [Node] = []
    /// Every group hangs off one hub: the account's EC2 inventory, which is the
    /// single call all of this came from. It also gives the layout something to
    /// orbit, so the picture reads as one fleet rather than scattered blobs.
    private var hubLabel = "EC2"
    private var hubTotal = 0
    private var timer: Timer?
    private var settleFrames = 0
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    /// Two seconds at sixty frames, then it holds still.
    private static let framesToSettle = 120

    /// How many groups get a name drawn. Beyond this the ring is more label than
    /// picture; the hovered node is always named on top of these.
    private var labelBudget: Int {
        max(6, Int(min(bounds.width, bounds.height) / 46))
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Stopped when the window goes away rather than in deinit: a timer holding
    /// the view keeps it alive, and deinit cannot touch main-actor state anyway.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil, settleFrames < ClusterView.framesToSettle {
            restart()
        }
    }

    // MARK: - Content

    func show(_ instances: [Instance], groupBy keys: [String], region: String = "") {
        hubTotal = instances.count
        hubLabel = region.isEmpty ? "EC2" : "EC2 · \(region)"
        let productKey = keys.first ?? TagMapping.Canonical.product
        let envKey = keys.count > 1 ? keys[1] : TagMapping.Canonical.env

        var byGroup: [String: [Instance]] = [:]
        for instance in instances {
            let product = value(instance, productKey)
            let env = value(instance, envKey)
            byGroup["\(product)\u{0}\(env)", default: []].append(instance)
        }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        nodes = byGroup.keys.sorted().enumerated().map { index, key in
            let members = byGroup[key] ?? []
            let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
            let product = parts.first.map(String.init) ?? ""
            let env = parts.count > 1 ? String(parts[1]) : ""
            // Seeded on a circle rather than at random: the same fleet settles
            // into the same picture, which is what makes it comparable.
            let angle = CGFloat(index) / CGFloat(max(1, byGroup.count)) * .pi * 2
            let seed = CGPoint(x: centre.x + cos(angle) * 140,
                               y: centre.y + sin(angle) * 110)
            let running = members.count { $0.state == "running" }
            let stopped = members.count { $0.state == "stopped" }
            return Node(
                label: env.isEmpty ? product : "\(product) · \(env)",
                product: product.isEmpty ? "untagged" : product,
                env: env.isEmpty ? nil : env,
                count: members.count, running: running, stopped: stopped,
                other: members.count - running - stopped,
                position: seed,
                // Area with the host count, so a group twice the size looks
                // twice the size. Floored so a single host is still clickable
                // and capped so one huge group cannot eat the view.
                radius: min(52, 9 + sqrt(CGFloat(members.count)) * 6),
                hostAngles: members.map { instance in
                    (angle: CGFloat(ClusterView.hash(instance.id) % 3600) / 3600 * .pi * 2,
                     state: instance.state)
                })
        }

        setAccessibilityLabel(accessibilitySummary())
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

    // MARK: - Simulation

    private func restart() {
        settleFrames = 0
        timer?.invalidate()
        guard !nodes.isEmpty else { needsDisplay = true; return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // Solved, not animated: the same final picture without the motion.
            for _ in 0..<ClusterView.framesToSettle { step() }
            needsDisplay = true
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return }
        guard settleFrames < ClusterView.framesToSettle else {
            timer?.invalidate()
            timer = nil
            return
        }
        settleFrames += 1
        step()
        needsDisplay = true
    }

    /// Repulsion between every pair, a pull to the centre, and a light spring
    /// between nodes of the same product so a product reads as one cluster.
    private func step() {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // The ring is sized by what has to fit on it, not by the view: two dozen
        // groups pulled onto one small circle became a pile that repulsion then
        // shoved off the edges. Circumference first, then clamped to the view.
        let needed = nodes.reduce(0) { $0 + $1.radius * 2 + 34 }
        let orbit = min(max(96, needed / (2 * .pi)),
                        min(bounds.width, bounds.height) * 0.40)
        for index in nodes.indices {
            let toCentre = CGVector(dx: centre.x - nodes[index].position.x,
                                    dy: centre.y - nodes[index].position.y)
            let distance = max(1, hypot(toCentre.dx, toCentre.dy))
            // A spring to the orbit, not to the centre: positive pull when the
            // node is outside it, a push when it has drifted over the hub.
            let pull = (distance - orbit) * 0.02
            var force = CGVector(dx: toCentre.dx / distance * pull,
                                 dy: toCentre.dy / distance * pull)
            for other in nodes.indices where other != index {
                let dx = nodes[index].position.x - nodes[other].position.x
                let dy = nodes[index].position.y - nodes[other].position.y
                let distance = max(24, (dx * dx + dy * dy).squareRoot())
                let wanted = nodes[index].radius + nodes[other].radius + 78
                let push = distance < wanted ? (wanted - distance) * 0.22 : 900 / (distance * distance)
                force.dx += dx / distance * push
                force.dy += dy / distance * push
                if nodes[index].product == nodes[other].product {
                    force.dx -= dx * 0.006
                    force.dy -= dy * 0.006
                }
            }
            nodes[index].velocity.dx = (nodes[index].velocity.dx + force.dx) * 0.86
            nodes[index].velocity.dy = (nodes[index].velocity.dy + force.dy) * 0.86
            nodes[index].position.x += nodes[index].velocity.dx
            nodes[index].position.y += nodes[index].velocity.dy
        }
        // Kept inside the view, with room for the host ring and the label.
        for index in nodes.indices {
            let margin = nodes[index].radius + 26
            nodes[index].position.x = min(max(margin, nodes[index].position.x),
                                          bounds.width - margin)
            nodes[index].position.y = min(max(margin, nodes[index].position.y),
                                          bounds.height - margin)
        }
    }

    override func layout() {
        super.layout()
        restart()
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
        let hubRadius: CGFloat = 34

        // Spokes first, so every circle sits on top of its own line.
        context.setStrokeColor(Brand.Color.textSecondary.withAlphaComponent(0.28).cgColor)
        for node in nodes {
            let delta = CGVector(dx: node.position.x - centre.x,
                                 dy: node.position.y - centre.y)
            let distance = max(1, hypot(delta.dx, delta.dy))
            let unit = CGVector(dx: delta.dx / distance, dy: delta.dy / distance)
            // Trimmed at both ends so the line touches neither circle.
            let from = CGPoint(x: centre.x + unit.dx * (hubRadius + 2),
                               y: centre.y + unit.dy * (hubRadius + 2))
            let to = CGPoint(x: node.position.x - unit.dx * (node.radius + 2),
                             y: node.position.y - unit.dy * (node.radius + 2))
            guard distance > hubRadius + node.radius + 6 else { continue }
            // Weight carries the same fact as the circle's size, quietly.
            context.setLineWidth(max(0.6, min(2.4, sqrt(CGFloat(node.count)) * 0.5)))
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }

        // Hosts, batched by state so the whole ring is a few fills rather
        // than one per host.
        for state in ["running", "stopped", "pending", "terminated"] {
            let colour = Brand.Color.state(for: state)
            context.setFillColor(colour.withAlphaComponent(0.85).cgColor)
            let path = CGMutablePath()
            for node in nodes {
                let ring = node.radius + 12
                for host in node.hostAngles where host.state == state {
                    let point = CGPoint(x: node.position.x + cos(host.angle) * ring,
                                        y: node.position.y + sin(host.angle) * ring)
                    path.addEllipse(in: CGRect(x: point.x - 2.2, y: point.y - 2.2,
                                               width: 4.4, height: 4.4))
                }
            }
            context.addPath(path)
            context.fillPath()
        }

        for (index, node) in nodes.enumerated() {
            let rect = CGRect(x: node.position.x - node.radius,
                              y: node.position.y - node.radius,
                              width: node.radius * 2, height: node.radius * 2)
            context.setFillColor(Brand.Color.surfaceRaised.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor((index == hovered ? Brand.Color.accent
                                    : Brand.Color.textSecondary).cgColor)
            context.setLineWidth(index == hovered ? 2 : 1)
            context.strokeEllipse(in: rect)

            let label = "\(node.count)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Brand.Color.textPrimary,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: node.position.x - size.width / 2,
                                                 y: node.position.y - size.height / 2),
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: Brand.Color.textPrimary,
        ]
        let totalSize = (total as NSString).size(withAttributes: totalAttributes)
        (total as NSString).draw(at: CGPoint(x: centre.x - totalSize.width / 2,
                                             y: centre.y - totalSize.height / 2 - 6),
                                 withAttributes: totalAttributes)
        let hostsWord: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: Brand.Color.textSecondary,
        ]
        let word = hubTotal == 1 ? "host" : "hosts"
        let wordSize = (word as NSString).size(withAttributes: hostsWord)
        (word as NSString).draw(at: CGPoint(x: centre.x - wordSize.width / 2,
                                            y: centre.y + 8),
                                withAttributes: hostsWord)

        let hubName = hubLabel
        let hubAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
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
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: index == hovered ? Brand.Color.textPrimary
                                                   : Brand.Color.textSecondary,
            ]
            let size = (name as NSString).size(withAttributes: attributes)
            let origin = CGPoint(x: node.position.x - size.width / 2,
                                 y: node.position.y + node.radius + 18)
            let pill = CGRect(x: origin.x - 5, y: origin.y - 2,
                              width: size.width + 10, height: size.height + 4)
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
            hypot(node.position.x - point.x, node.position.y - point.y) <= node.radius + 12
        }
        guard found != hovered else { return }
        hovered = found
        toolTip = found.map { index in
            let node = nodes[index]
            return "\(node.label): \(node.count) hosts, \(node.running) running, "
                + "\(node.stopped) stopped"
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        toolTip = nil
        needsDisplay = true
    }

    private func accessibilitySummary() -> String {
        let hosts = nodes.reduce(0) { $0 + $1.count }
        let running = nodes.reduce(0) { $0 + $1.running }
        return "Fleet cluster: \(hosts) hosts in \(nodes.count) groups, \(running) running. "
            + "The panels below say the same in text."
    }
}
