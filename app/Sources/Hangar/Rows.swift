import AppKit
import HangarCore

/// Sticky product header: 24 pt, semibold name left, result count right.
/// Environment deliberately gets no header of its own.
final class ProductHeaderView: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = Brand.Font.groupHeader
        count.font = Brand.Font.groupHeader
        count.alignment = .right
        for field in [name, count] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Brand.Metric.space16),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -Brand.Metric.space16),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(product: String, count total: Int) {
        // Not uppercased. This is an EC2 tag value, and a product genuinely
        // named macOS must not render as MACOS. The tracking and the small
        // secondary font carry the header look without touching the name.
        name.attributedStringValue = NSAttributedString(
            string: product,
            attributes: [.font: Brand.Font.groupHeader,
                         .foregroundColor: Brand.Color.textSecondary,
                         .kern: Brand.Font.groupHeaderTracking])
        self.count.attributedStringValue = NSAttributedString(
            string: "\(total)",
            attributes: [.font: Brand.Font.groupHeader,
                         .foregroundColor: Brand.Color.textSecondary,
                         // Tabular figures keep counts from shifting as they change.
                         .kern: 0])
        self.count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        toolTip = nil
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(product), \(total) hosts")
    }
}

/// One host row, 48 pt. Draws its own selection capsule and rails so the brand
/// geometry is exact; NSTableView's own highlight is switched off.
final class HostRowView: NSTableCellView {
    private let aliasField = NSTextField(labelWithString: "")
    private let metadataField = NSTextField(labelWithString: "")
    private let stateGlyph = NSImageView()
    private let asgGlyph = NSImageView()
    private let prodBadge = BadgeView()
    private let divider = NSView()

    private var isProduction = false
    private var isSelectedRow = false
    private var fullHostname = ""
    private var fullAlias = ""
    private var aliasMatches: [Range<String.Index>] = []
    private var hostMatches: [Range<String.Index>] = []
    private var stateName = ""
    private var metadataEnvironment: String?
    /// Shown only when the host did not come from EC2. Where a host came from is
    /// the first question anyone asks about one they did not expect to see, and
    /// printing "ec2" on every row of an all-EC2 fleet would answer it for nobody.
    private var metadataSource: String?

    override var isFlipped: Bool { true }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true

        aliasField.cell?.lineBreakMode = .byClipping
        metadataField.cell?.lineBreakMode = .byClipping
        stateGlyph.imageScaling = .scaleProportionallyUpOrDown
        asgGlyph.imageScaling = .scaleProportionallyUpOrDown
        asgGlyph.image = Brand.Glyph.autoscalingGroup
        divider.wantsLayer = true

        for view in [divider, stateGlyph, asgGlyph, prodBadge, aliasField, metadataField] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    private var capsule: NSRect {
        NSRect(x: Brand.Metric.selectionInsetHorizontal,
               y: Brand.Metric.selectionInsetVertical,
               width: bounds.width - Brand.Metric.selectionInsetHorizontal * 2,
               height: Brand.Metric.selectedRowHeight)
    }

    override func layout() {
        super.layout()
        let capsule = self.capsule
        let railWidth = isProduction ? Brand.Metric.productionRailWidth
                                     : Brand.Metric.selectionRailWidth
        let glyphOrigin = capsule.minX + railWidth + Brand.Metric.space4
        let glyphSize = Brand.Metric.glyphSize
        stateGlyph.frame = NSRect(x: glyphOrigin,
                                  y: capsule.midY - glyphSize / 2,
                                  width: glyphSize, height: glyphSize)

        let textLeading = stateGlyph.frame.maxX + Brand.Metric.space8
        let textTrailing = bounds.width - Brand.Metric.space12
        let textWidth = max(40, textTrailing - textLeading)

        // The brand kit's 48pt row put a 35pt block of text inside a 40pt capsule,
        // which reads as cramped however the baselines are nudged. The row is
        // 56pt and the capsule 48pt, with the pair centred in it: six points of
        // air above the alias and seven below the metadata.
        aliasField.frame = NSRect(x: textLeading, y: 24 - 14,
                                  width: textWidth, height: 18)
        var metadataX = textLeading
        if isProduction {
            let badgeSize = prodBadge.intrinsicSize
            prodBadge.frame = NSRect(x: metadataX, y: 42 - 12,
                                     width: badgeSize.width, height: badgeSize.height)
            metadataX += badgeSize.width + Brand.Metric.space8
        }
        prodBadge.isHidden = !isProduction

        if !asgGlyph.isHidden {
            asgGlyph.frame = NSRect(x: metadataX, y: 42 - 12, width: 14, height: 14)
            metadataX += 14 + Brand.Metric.space4
        }
        metadataField.frame = NSRect(x: metadataX, y: 42 - 12,
                                     width: max(40, textTrailing - metadataX), height: 15)
        divider.frame = NSRect(x: Brand.Metric.space16, y: 0,
                               width: bounds.width - Brand.Metric.space16 * 2, height: 1)
        divider.layer?.backgroundColor = Brand.Color.textPrimary
            .withAlphaComponent(Brand.Metric.dividerOpacity).cgColor

        renderText(width: textWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let capsule = self.capsule
        let radius = Brand.Metric.selectedRowRadius

        if isSelectedRow {
            let path = NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius)
            Brand.Color.selectionBackground.setFill()
            path.fill()
            // Keyboard focus is an accent inner ring, in addition to the fill.
            let inset = Brand.Metric.focusRingWidth / 2
            let ring = NSBezierPath(roundedRect: capsule.insetBy(dx: inset, dy: inset),
                                    xRadius: radius, yRadius: radius)
            ring.lineWidth = Brand.Metric.focusRingWidth
            Brand.Color.accent.setStroke()
            ring.stroke()
        }

        // The production rail is present whether or not the row is selected, and
        // it wins the leading edge: doubling it with the selection rail would
        // weaken the one signal that must never be ambiguous.
        let railWidth = isProduction ? Brand.Metric.productionRailWidth
                                     : Brand.Metric.selectionRailWidth
        if isProduction || isSelectedRow {
            let rail = NSRect(x: capsule.minX, y: capsule.minY,
                              width: railWidth, height: capsule.height)
            let path = NSBezierPath(roundedRect: rail,
                                    xRadius: railWidth / 2, yRadius: railWidth / 2)
            (isProduction ? Brand.Color.prodDanger : Brand.Color.accent).setFill()
            path.fill()
        }
    }

    // MARK: - Configuration

    func configure(entry: SearchEntry, matches: [Range<String.Index>],
                   hostMatches: [Range<String.Index>], showsDivider: Bool,
                   selected: Bool) {
        let instance = entry.instance
        fullAlias = entry.alias
        fullHostname = entry.hostname
        aliasMatches = matches
        self.hostMatches = hostMatches
        stateName = instance.state
        isProduction = instance.env.lowercased().contains("prod")
        isSelectedRow = selected
        metadataEnvironment = instance.env
        metadataSource = instance.origin == .ec2 ? nil : instance.origin.label
        divider.isHidden = !showsDivider

        stateGlyph.image = Brand.Glyph.forState(instance.state)
        asgGlyph.isHidden = !instance.isASG
        asgGlyph.setAccessibilityLabel(
            instance.isASG ? "In autoscaling group \(instance.asg)" : nil)
        prodBadge.text = "PROD"

        toolTip = fullHostname
        setAccessibilityRole(.row)
        var described = "\(fullAlias), \(instance.state)"
        if !instance.env.isEmpty { described += ", environment \(instance.env)" }
        if !instance.product.isEmpty { described += ", product \(instance.product)" }
        if isProduction { described += ", production" }
        if instance.isASG { described += ", in autoscaling group" }
        described += ", hostname \(fullHostname)"
        if let source = metadataSource { described += ", from \(source)" }
        setAccessibilityLabel(described)

        needsLayout = true
        needsDisplay = true
    }

    func updateSelection(_ selected: Bool) {
        guard selected != isSelectedRow else { return }
        isSelectedRow = selected
        needsLayout = true
        needsDisplay = true
    }

    /// Foreground switches to the selection colour for text and state glyphs; a
    /// production badge keeps its own pair, per the brand kit's contrast table.
    private var foreground: NSColor {
        isSelectedRow ? Brand.Color.selectionForeground : Brand.Color.textPrimary
    }
    private var secondaryForeground: NSColor {
        isSelectedRow ? Brand.Color.selectionForeground : Brand.Color.textSecondary
    }

    private func renderText(width: CGFloat) {
        let shown = Truncation.fitting(fullAlias, into: width,
                                       font: Brand.Font.hostPrimary,
                                       protecting: aliasMatches)
        aliasField.attributedStringValue = HostRowView.highlighted(
            shown, original: fullAlias, matches: aliasMatches,
            base: foreground, accent: Brand.Color.accent)
        aliasField.setAccessibilityLabel(fullAlias)

        stateGlyph.contentTintColor = isSelectedRow
            ? Brand.Color.selectionForeground : Brand.Color.state(for: stateName)
        stateGlyph.setAccessibilityLabel("State \(stateName)")
        asgGlyph.contentTintColor = secondaryForeground

        var parts: [String] = []
        if let env = metadataEnvironment, !env.isEmpty { parts.append(env) }
        parts.append(stateName)
        if let source = metadataSource { parts.append(source) }
        // Give the hostname whatever width is left after the fixed facts, measured
        // rather than estimated, so a long name uses the space it actually has.
        let lead = parts.isEmpty ? "" : parts.joined(separator: " \u{00B7} ") + " \u{00B7} "
        let leadWidth = (lead as NSString)
            .size(withAttributes: [.font: Brand.Font.metadata]).width
        let host = Truncation.fitting(fullHostname,
                                      into: metadataField.frame.width - leadWidth,
                                      font: Brand.Font.metadata,
                                      protecting: hostMatches)
        metadataField.attributedStringValue = NSAttributedString(
            string: lead + host,
            attributes: [.font: Brand.Font.metadata,
                         .foregroundColor: secondaryForeground])
        metadataField.setAccessibilityLabel(fullHostname)
        prodBadge.apply()
    }

    /// Matched runs go accent and semibold. Monospace keeps the advance width
    /// identical, so the row cannot shift as the query changes.
    static func highlighted(_ shown: String, original: String,
                            matches: [Range<String.Index>],
                            base: NSColor, accent: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: shown,
            attributes: [.font: Brand.Font.hostPrimary,
                         .foregroundColor: base,
                         .kern: Brand.Font.hostTracking])
        guard !matches.isEmpty else { return result }
        // Re-find the matched substrings inside the possibly truncated text so
        // highlighting survives middle truncation.
        var searchStart = shown.startIndex
        for range in matches {
            let fragment = String(original[range])
            guard let found = shown.range(of: fragment, options: [.caseInsensitive],
                                          range: searchStart..<shown.endIndex) else { continue }
            result.addAttributes([.foregroundColor: accent,
                                  .font: Brand.Font.hostMatched],
                                 range: NSRange(found, in: shown))
            searchStart = found.upperBound
        }
        return result
    }
}

/// The uppercase PROD badge. Its own background and foreground, never the
/// selection colours, so production stays identifiable on a selected row.
final class BadgeView: NSView {
    var text = "PROD"
    private let field = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: centerXAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var intrinsicSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: Brand.Font.metadataStrong])
        return NSSize(width: ceil(size.width) + 10, height: 15)
    }

    func apply() {
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: Brand.Font.metadataStrong,
                         .foregroundColor: Brand.Color.prodDanger,
                         .kern: 0.3])
        layer?.backgroundColor = Brand.Color.prodBackground.cgColor
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Production")
    }
}

/// Transient 28 pt footer: Return to connect, Command-Return to copy, cache age.
final class FooterView: NSView {
    private let hints = NSTextField(labelWithString: "")
    private let copyGlyph = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private var revertWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hints.font = Brand.Font.shortcut
        status.font = Brand.Font.shortcut
        status.alignment = .right
        copyGlyph.imageScaling = .scaleProportionallyUpOrDown
        for view in [copyGlyph, hints, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            copyGlyph.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: Brand.Metric.space16),
            copyGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyGlyph.widthAnchor.constraint(equalToConstant: 14),
            copyGlyph.heightAnchor.constraint(equalToConstant: 14),
            hints.leadingAnchor.constraint(equalTo: copyGlyph.trailingAnchor,
                                           constant: Brand.Metric.space8),
            hints.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -Brand.Metric.space16),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @MainActor
    func update(store: FleetStore, resultCount: Int, totalCount: Int) {
        hints.attributedStringValue = NSAttributedString(
            string: "\u{21A9} Connect    \u{2318}\u{21A9} Copy    \u{2318}E Edit",
            attributes: [.font: Brand.Font.shortcut,
                         .foregroundColor: Brand.Color.textSecondary])
        var right = "\(resultCount) of \(totalCount)"
        if case .refreshing = store.status {
            right = "Refreshing\u{2026}"
        } else if case .failed(let message) = store.status {
            right = message
        } else if let age = store.cacheAgeDescription {
            right += "    " + age
        }
        status.attributedStringValue = NSAttributedString(
            string: right,
            attributes: [.font: Brand.Font.shortcut,
                         .foregroundColor: Brand.Color.textSecondary])
        let stale = store.isStale
        copyGlyph.image = stale ? Brand.Glyph.staleCache : nil
        copyGlyph.contentTintColor = Brand.Color.statePending
        copyGlyph.setAccessibilityLabel(stale ? "Cache is stale" : nil)
        copyGlyph.isHidden = !stale && revertWork == nil
    }

    /// After a successful copy the copied glyph appears for 1.2 s, then the
    /// footer returns to its normal state.
    func flashCopied() {
        revertWork?.cancel()
        copyGlyph.isHidden = false
        copyGlyph.image = Brand.Glyph.copied
        copyGlyph.contentTintColor = Brand.Color.accent
        copyGlyph.setAccessibilityLabel("Copied to clipboard")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.revertWork = nil
            self.copyGlyph.image = nil
            self.copyGlyph.isHidden = true
        }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Brand.Metric.copiedGlyphDuration,
                                      execute: work)
    }
}
