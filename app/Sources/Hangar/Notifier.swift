import AppKit

/// Transient feedback without asking for notification permission. A small HUD
/// that fades itself out keeps the app prompt-free on first launch, which matters
/// for a utility whose whole pitch is that it needs nothing set up.
@MainActor
enum Notifier {
    private static var hud: NSPanel?

    static func show(title: String, body: String? = nil, seconds: TimeInterval = 1.6) {
        hud?.orderOut(nil)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Brand.Color.textPrimary
        label.alignment = .center

        var views: [NSView] = [label]
        if let body, !body.isEmpty {
            let detail = NSTextField(labelWithString: body)
            // Paths, commands, regions and aliases stay literal and monospaced.
            detail.font = Brand.Font.shortcut
            detail.textColor = Brand.Color.textSecondary
            detail.alignment = .center
            detail.lineBreakMode = .byTruncatingMiddle
            detail.maximumNumberOfLines = 2
            views.append(detail)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)

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

        let fitting = stack.fittingSize
        let width = min(max(fitting.width, 220), 520)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: fitting.height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = container
        panel.ignoresMouseEvents = true

        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2,
                                         y: frame.minY + frame.height * 0.18))
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
