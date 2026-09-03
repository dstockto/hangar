import AppKit

/// Transient feedback without asking for notification permission. A small HUD
/// that fades itself out keeps the app prompt-free on first launch, which matters
/// for a utility whose whole pitch is that it needs nothing set up.
@MainActor
enum Notifier {
    private static var hud: NSPanel?

    /// Where the menubar item is, so a notice can appear under the thing it came
    /// from. Set by the menubar controller; without it the notice falls back to
    /// the top right corner, which is still the app's own end of the screen.
    static var anchor: (() -> NSRect?)?

    /// Takes the HUD down now. A modal alert does not run the main queue, so a HUD
    /// still up when one opens would sit under it until the alert was dismissed.
    static func dismiss() {
        hud?.orderOut(nil)
        hud = nil
    }

    /// The widest the text column is allowed to get, and the space around it.
    /// Both are needed as numbers rather than left to the layout: a stack view
    /// reports a fitting width that leaves its own insets out, so sizing the
    /// panel from that measurement printed the text against the card's edge.
    private static let column: CGFloat = 300
    private static let padding = NSEdgeInsets(top: 20, left: 26, bottom: 20, right: 26)

    static func show(title: String, body: String? = nil, seconds: TimeInterval = 1.6) {
        hud?.orderOut(nil)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Brand.Color.textPrimary
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = Notifier.column

        var views: [NSView] = [label]
        if let body, !body.isEmpty {
            let detail = NSTextField(labelWithString: body)
            // Paths, commands, regions and aliases stay literal and monospaced.
            detail.font = Brand.Font.shortcut
            detail.textColor = Brand.Color.textSecondary
            detail.alignment = .center
            // Wrapped rather than truncated: a long reason used to stretch the
            // notice into a banner across the whole screen, which read as an
            // operating system alert rather than as this app saying something.
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 3
            detail.preferredMaxLayoutWidth = Notifier.column
            views.append(detail)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = Notifier.padding

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        // Brand panel colour beneath the material, so the HUD stays legible with
        // Reduce Transparency enabled.
        let fallback = NSView()
        fallback.wantsLayer = true
        fallback.layer?.backgroundColor = Brand.Color.panel
            .withAlphaComponent(Brand.Metric.panelFallbackOpacity).cgColor

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [fallback, effect, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            fallback.topAnchor.constraint(equalTo: container.topAnchor),
            fallback.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fallback.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fallback.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // The text column is measured, then the padding is added to it. The
        // stack's own fitting width does not include its insets, so using it as
        // the panel width left the wrapped body nothing to sit inside.
        let text = views.map(\.intrinsicContentSize.width).max() ?? Notifier.column
        let column = min(max(text, 210), Notifier.column)
        let width = column + Notifier.padding.left + Notifier.padding.right
        let fitting = stack.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: fitting.height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = container
        panel.ignoresMouseEvents = true

        // Under the menubar item, not across the middle of the screen.
        if let screen = NSScreen.main?.visibleFrame {
            let height = panel.frame.height
            var x = screen.maxX - width - 12
            if let item = Notifier.anchor?() {
                x = min(screen.maxX - width - 12,
                        max(screen.minX + 12, item.midX - width / 2))
            }
            panel.setFrameOrigin(NSPoint(x: x, y: screen.maxY - height - 10))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hud = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if hud === panel { hud = nil }
                }
            })
        }
    }
}
