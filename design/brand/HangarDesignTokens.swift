import AppKit

enum HangarColor {
    static let canvas = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x111418) : hex(0xF6F7F8) }
    static let panel = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x171B20) : hex(0xFFFFFF) }
    static let surfaceRaised = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x1D2228) : hex(0xE9EDF1) }
    static let textPrimary = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xF3F6F8) : hex(0x15191D) }
    static let textSecondary = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xAAB3BD) : hex(0x59636D) }
    static let accent = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x57B9FF) : hex(0x006EAD) }
    static let selectionBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x163A52) : hex(0xD9EEFF) }
    static let selectionForeground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xFFFFFF) : hex(0x004B77) }
    static let running = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x49C983) : hex(0x167548) }
    static let stopped = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xB2BAC2) : hex(0x59636D) }
    static let pending = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xF0C15A) : hex(0x8A5A00) }
    static let terminated = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xF07880) : hex(0xB32632) }
    static let prodBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0x45191F) : hex(0xFFE1E4) }
    static let prodDanger = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(0xFF8C96) : hex(0xA60017) }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }
}

enum HangarType {
    static let search = NSFont.systemFont(ofSize: 18, weight: .regular)
    static let hostPrimary = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    static let metadata = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let groupHeader = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let shortcut = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

enum HangarMetric {
    static let panelWidth: CGFloat = 640
    static let panelInitialHeight: CGFloat = 456
    static let panelCornerRadius: CGFloat = 18
    static let hostRowHeight: CGFloat = 48
    static let groupHeaderHeight: CGFloat = 24
    static let selectedRowHeight: CGFloat = 40
    static let selectedRowRadius: CGFloat = 9
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
}

