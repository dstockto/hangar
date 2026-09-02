import AppKit

/// The single source of brand values, all of them resolved from the supplied
/// HangarAssets catalog. Nothing here re-declares a hex value: named colors are
/// the implementation contract, so a missing asset is a build error surfaced by
/// `make verify-assets`, not something to paper over with a duplicate palette.
enum Brand {

    // MARK: - Colors

    enum Color {
        static var canvas: NSColor { named("canvas", fallback: .windowBackgroundColor) }
        static var panel: NSColor { named("panel", fallback: .controlBackgroundColor) }
        static var surfaceRaised: NSColor { named("surfaceRaised", fallback: .underPageBackgroundColor) }
        static var textPrimary: NSColor { named("textPrimary", fallback: .labelColor) }
        static var textSecondary: NSColor { named("textSecondary", fallback: .secondaryLabelColor) }
        static var accent: NSColor { named("accent", fallback: .controlAccentColor) }
        static var selectionBackground: NSColor {
            named("selectionBackground", fallback: .selectedContentBackgroundColor)
        }
        static var selectionForeground: NSColor {
            named("selectionForeground", fallback: .selectedMenuItemTextColor)
        }
        static var stateRunning: NSColor { named("stateRunning", fallback: .systemGreen) }
        static var stateStopped: NSColor { named("stateStopped", fallback: .systemGray) }
        static var statePending: NSColor { named("statePending", fallback: .systemYellow) }
        static var stateTerminated: NSColor { named("stateTerminated", fallback: .systemRed) }
        static var prodDanger: NSColor { named("prodDanger", fallback: .systemPink) }
        static var prodBackground: NSColor { named("prodBackground", fallback: .systemRed) }

        /// Colour for an instance state. Never used on its own: every caller pairs
        /// it with the matching state glyph, per the brand kit's accessibility rule.
        static func state(for state: String) -> NSColor {
            switch state {
            case "running":             return stateRunning
            case "stopped":             return stateStopped
            case "pending", "stopping": return statePending
            default:                    return stateTerminated
            }
        }

        static let allNames = [
            "canvas", "panel", "surfaceRaised", "textPrimary", "textSecondary",
            "accent", "selectionBackground", "selectionForeground", "stateRunning",
            "stateStopped", "statePending", "stateTerminated", "prodDanger",
            "prodBackground",
        ]

        private static func named(_ name: String, fallback: NSColor) -> NSColor {
            guard let color = NSColor(named: name) else {
                assertionFailure("Missing colour asset '\(name)' in HangarAssets")
                return fallback
            }
            return color
        }
    }

    // MARK: - Typography

    /// Computed rather than stored, like the colours above: a stored NSFont is
    /// global state of a non-Sendable type, and AppKit caches these anyway.
    enum Font {
        static var search: NSFont { .systemFont(ofSize: 18, weight: .regular) }
        static var hostPrimary: NSFont { .monospacedSystemFont(ofSize: 13, weight: .medium) }
        static var metadata: NSFont { .systemFont(ofSize: 11, weight: .regular) }
        static var metadataStrong: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
        static var groupHeader: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
        static var shortcut: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }
        /// Matched runs go semibold in the accent colour; monospace keeps the
        /// advance width identical so the row cannot shift as the query changes.
        static var hostMatched: NSFont { .monospacedSystemFont(ofSize: 13, weight: .semibold) }

        static let hostTracking: CGFloat = -0.1
        static let groupHeaderTracking: CGFloat = 0.25
    }

    // MARK: - Metrics

    enum Metric {
        static let panelWidth: CGFloat = 640
        static let panelInitialHeight: CGFloat = 456
        static let panelMinSize = NSSize(width: 520, height: 240)
        static let panelMaxSize = NSSize(width: 760, height: 620)
        static let panelCornerRadius: CGFloat = 18
        static let panelTopFraction: CGFloat = 0.18

        static let searchRegionHeight: CGFloat = 56
        static let hostRowHeight: CGFloat = 48
        static let selectedRowHeight: CGFloat = 40
        static let selectedRowRadius: CGFloat = 9
        static let selectionInsetVertical: CGFloat = 4
        static let selectionInsetHorizontal: CGFloat = 14
        static let selectionRailWidth: CGFloat = 2
        static let productionRailWidth: CGFloat = 3
        static let focusRingWidth: CGFloat = 1.5
        static let groupHeaderHeight: CGFloat = 24
        static let footerHeight: CGFloat = 28
        static let glyphSize: CGFloat = 16
        static let statusGlyphSize: CGFloat = 18

        static let space4: CGFloat = 4
        static let space8: CGFloat = 8
        static let space12: CGFloat = 12
        static let space16: CGFloat = 16
        static let space24: CGFloat = 24
        static let space32: CGFloat = 32
        /// Twice the major edge inset, for the width of a two-sided 24 pt margin.
        static let space48: CGFloat = 48

        static let panelFallbackOpacity: CGFloat = 0.86
        static let separatorOpacity: CGFloat = 0.08
        static let dividerOpacity: CGFloat = 0.24
        static let narrowAnimation: TimeInterval = 0.09
        static let collapseAnimation: TimeInterval = 0.14
        static let collapseDelay: TimeInterval = 0.12
        static let copiedGlyphDuration: TimeInterval = 1.2
        static let tooltipDelay: TimeInterval = 0.6
    }

    // MARK: - Glyphs

    /// Supplied vector template glyphs. Rendered as templates so the semantic
    /// foreground colour comes from `contentTintColor`, never from the artwork.
    enum Glyph {
        static var environment: NSImage? { template("EnvironmentIcon") }
        static var product: NSImage? { template("ProductIcon") }
        static var autoscalingGroup: NSImage? { template("AutoscalingGroupIcon") }
        static var running: NSImage? { template("RunningIcon") }
        static var stopped: NSImage? { template("StoppedIcon") }
        static var copied: NSImage? { template("CopiedIcon") }
        static var staleCache: NSImage? { template("StaleCacheIcon") }

        /// Pending and stopping reuse the stopped geometry; terminated reuses it
        /// too. Colour alone never carries state, so each is paired with its
        /// state colour and an accessibility description naming the state.
        static func forState(_ state: String) -> NSImage? {
            switch state {
            case "running": return running
            default:        return stopped
            }
        }

        static let allNames = [
            "EnvironmentIcon", "ProductIcon", "AutoscalingGroupIcon", "RunningIcon",
            "StoppedIcon", "CopiedIcon", "StaleCacheIcon", "HangarWordmarkTemplate",
        ]

        /// The wordmark lockup, rendered as a template so one asset serves light,
        /// dark and increased contrast. The supplied artwork is 420x96, and the
        /// brand kit sets 132 pt as the floor before the standalone mark is used
        /// instead, so the height follows from the width rather than the reverse.
        static func wordmark(width: CGFloat = 154) -> NSImage? {
            guard let image = NSImage(named: "HangarWordmarkTemplate") else {
                assertionFailure("Missing HangarWordmarkTemplate in HangarAssets")
                return nil
            }
            let copy = image.copy() as! NSImage
            copy.isTemplate = true
            copy.size = NSSize(width: width, height: (width * 96 / 420).rounded())
            return copy
        }

        /// A system symbol as a template image. Used where the brand set has no
        /// glyph of its own, chiefly the Help menu, where every row earns an icon
        /// and inventing a dozen brand glyphs for it would be worse than using
        /// the platform's. Returns nil rather than asserting: a symbol missing on
        /// an older system should cost the icon, not the row.
        static func symbol(_ name: String, size: CGFloat = 13,
                           weight: NSFont.Weight = .regular) -> NSImage? {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            else { return nil }
            let configured = image.withSymbolConfiguration(
                .init(pointSize: size, weight: weight)) ?? image
            configured.isTemplate = true
            return configured
        }

        static func template(_ name: String, size: CGFloat = Metric.glyphSize) -> NSImage? {
            guard let image = NSImage(named: name) else {
                assertionFailure("Missing image asset '\(name)' in HangarAssets")
                return nil
            }
            let copy = image.copy() as! NSImage
            copy.isTemplate = true
            copy.size = NSSize(width: size, height: size)
            return copy
        }
    }

    /// The production menubar glyph. Primary only; the alternates stay in
    /// docs/brand for future evaluation and are not bundled.
    static func statusItemImage() -> NSImage? {
        guard let image = NSImage(named: "HangarStatusTemplate") else {
            assertionFailure("Missing HangarStatusTemplate asset")
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: Metric.statusGlyphSize, height: Metric.statusGlyphSize)
        return image
    }

    // MARK: - Verification

    /// Backs `make verify-assets`. Every supplied name must resolve inside the
    /// built bundle, and the menubar glyph must be a template at 18 x 18.
    static func verifyAssets() -> [String] {
        var problems: [String] = []
        for name in Color.allNames where NSColor(named: name) == nil {
            problems.append("colour '\(name)' does not resolve")
        }
        for name in Glyph.allNames {
            guard let image = NSImage(named: name) else {
                problems.append("image '\(name)' does not resolve")
                continue
            }
            if !image.isTemplate {
                problems.append("image '\(name)' is not a template asset")
            }
        }
        guard let status = NSImage(named: "HangarStatusTemplate") else {
            problems.append("HangarStatusTemplate does not resolve")
            return problems
        }
        if !status.isTemplate {
            problems.append("HangarStatusTemplate is not a template asset")
        }
        let reps = status.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
        if !reps.contains("18x18") || !reps.contains("36x36") {
            problems.append("HangarStatusTemplate lacks 1x/2x reps, found \(reps)")
        }
        return problems
    }

    static func printVerification() {
        let problems = verifyAssets()
        print("Hangar asset verification")
        print("  colours: \(Color.allNames.count)   glyphs: \(Glyph.allNames.count)   status: 1")
        if problems.isEmpty {
            if let status = statusItemImage() {
                print("  status glyph: template=\(status.isTemplate) size=\(Int(status.size.width))x\(Int(status.size.height))pt reps=\(status.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ","))")
            }
            for name in Color.allNames {
                let dark = NSAppearance(named: .darkAqua)!
                let light = NSAppearance(named: .aqua)!
                var d = "", l = ""
                dark.performAsCurrentDrawingAppearance { d = Brand.hex(NSColor(named: name)!) }
                light.performAsCurrentDrawingAppearance { l = Brand.hex(NSColor(named: name)!) }
                print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) dark \(d)  light \(l)")
            }
            print("  all assets resolve")
        } else {
            for problem in problems { print("  FAIL \(problem)") }
        }
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}
