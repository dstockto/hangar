import AppKit
import HangarCore

/// About Hangar.
///
/// A window of its own rather than `orderFrontStandardAboutPanel`: the standard
/// panel lays its credits out flush left and renders a link as plain text, and
/// the one thing worth clicking here is the repository.
@MainActor
final class AboutWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        super.init()
        build()
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Hangar"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        // The lockup, not a text label: the wordmark is custom geometry, so
        // setting "Hangar" in the system font would be a different mark.
        let name = NSImageView()
        name.image = Brand.Glyph.wordmark(width: 196)
        name.contentTintColor = Brand.Color.textPrimary
        name.imageScaling = .scaleProportionallyUpOrDown
        name.setAccessibilityLabel("Hangar")

        let version = NSTextField(labelWithString: "Version \(Updates.bundleVersion)")
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        version.textColor = Brand.Color.textSecondary
        version.alignment = .center

        let tagline = NSTextField(labelWithString: "Your fleet, one keystroke away.")
        tagline.font = .systemFont(ofSize: 13, weight: .medium)
        tagline.textColor = Brand.Color.textPrimary
        tagline.alignment = .center

        let blurb = NSTextField(wrappingLabelWithString:
            "Spotlight for your SSH hosts. A native macOS launcher that turns "
            + "changing EC2 instances into stable, searchable SSH targets.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = Brand.Color.textSecondary
        blurb.alignment = .center
        blurb.preferredMaxLayoutWidth = 300

        // The repository link: mark plus text, as one centered clickable row.
        let link = LinkButton(title: "github.com/goriparthi/hangar",
                              image: Mark.github(size: 14),
                              url: Updates.repoURL)

        let copyright = NSTextField(labelWithString: "MIT licensed")
        copyright.font = .systemFont(ofSize: 10)
        copyright.textColor = Brand.Color.textSecondary.withAlphaComponent(0.7)
        copyright.alignment = .center

        let stack = NSStackView(views: [icon, name, version, tagline, blurb, link, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Brand.Metric.space8
        stack.setCustomSpacing(Brand.Metric.space16, after: icon)
        stack.setCustomSpacing(Brand.Metric.space16, after: blurb)
        stack.setCustomSpacing(Brand.Metric.space16, after: link)
        stack.edgeInsets = NSEdgeInsets(top: Brand.Metric.space24, left: Brand.Metric.space24,
                                        bottom: Brand.Metric.space24, right: Brand.Metric.space24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
            name.widthAnchor.constraint(equalToConstant: 196),
            name.heightAnchor.constraint(equalToConstant: 45),
            blurb.widthAnchor.constraint(equalToConstant: 300),
        ])
        window.contentView = content
        self.window = window
    }

    func show() {
        AppMainMenu.install()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppMainMenu.release()
        onClose?()
    }
}

/// A mark plus a label that opens a URL, drawn as one row so the pair centers as
/// a unit. A plain NSButton would center its title and leave the image adrift.
@MainActor
final class LinkButton: NSView {
    private let url: URL
    private let label = NSTextField(labelWithString: "")
    private let markView = NSImageView()
    private var tracking: NSTrackingArea?

    init(title: String, image: NSImage?, url: URL) {
        self.url = url
        super.init(frame: .zero)

        markView.image = image
        markView.contentTintColor = Brand.Color.accent
        markView.imageScaling = .scaleProportionallyUpOrDown

        label.stringValue = title
        label.font = Brand.Font.shortcut
        label.textColor = Brand.Color.accent

        let row = NSStackView(views: [markView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Brand.Metric.space8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            markView.widthAnchor.constraint(equalToConstant: 14),
            markView.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        label.attributedStringValue = NSAttributedString(
            string: label.stringValue,
            attributes: [.font: Brand.Font.shortcut,
                         .foregroundColor: Brand.Color.accent,
                         .underlineStyle: NSUnderlineStyle.single.rawValue])
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        label.attributedStringValue = NSAttributedString(
            string: label.stringValue,
            attributes: [.font: Brand.Font.shortcut,
                         .foregroundColor: Brand.Color.accent])
    }

    override func mouseDown(with event: NSEvent) {
        NSWorkspace.shared.open(url)
    }
}
