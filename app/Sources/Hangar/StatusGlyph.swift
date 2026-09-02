import AppKit

/// Builds a two-tone menubar glyph from the supplied template artwork by
/// separating its two connected shapes: the hangar shell and the aircraft.
///
/// This is a deliberate departure from the brand kit, which requires the status
/// glyph to stay a pure template image so macOS can invert it. The artwork is not
/// redrawn: the shapes are recovered from the supplied PNG, the shell is painted
/// in the menubar's own foreground colour, and only the aircraft is tinted. The
/// unmodified template is still used whenever the menu is open or the cache is
/// not fresh, so the states where inversion matters most stay spec-pure.
/// Main-actor isolated because of the cache below: it is plain mutable static
/// state, and only the main thread ever draws a menubar item.
@MainActor
enum StatusGlyph {
    private struct CacheKey: Hashable {
        let shell: String
        let aircraft: String
    }

    private static var cache: [CacheKey: NSImage] = [:]

    /// The unmodified supplied template, used for the highlighted and stale states.
    static func plain() -> NSImage? { Brand.statusItemImage() }

    /// Shell in `shell`, aircraft in `aircraft`. Returns nil, so callers fall back
    /// to the template, if the artwork does not split into exactly two shapes.
    static func twoTone(shell: NSColor, aircraft: NSColor) -> NSImage? {
        let key = CacheKey(shell: Brand.hex(shell), aircraft: Brand.hex(aircraft))
        if let cached = cache[key] { return cached }
        guard let source = NSImage(named: "HangarStatusTemplate") else { return nil }

        let output = NSImage(size: NSSize(width: Brand.Metric.statusGlyphSize,
                                          height: Brand.Metric.statusGlyphSize))
        var produced = 0
        // Asset-catalog images do not hand back NSBitmapImageRep, so render the
        // template into bitmaps we own at both scales and work from those.
        let points = Int(Brand.Metric.statusGlyphSize)
        for scale in [1, 2] {
            guard let rendered = rasterize(source, pixels: points * scale),
                  let tinted = recolor(rendered, shell: shell, aircraft: aircraft)
            else { continue }
            output.addRepresentation(tinted)
            produced += 1
        }
        guard produced > 0 else { return nil }
        output.isTemplate = false          // it carries colour now, so not a template
        output.size = NSSize(width: Brand.Metric.statusGlyphSize,
                             height: Brand.Metric.statusGlyphSize)
        cache[key] = output
        return output
    }

    static func invalidateCache() { cache.removeAll() }

    // MARK: - Shape separation

    /// Draws the template into a bitmap of a known layout at a known size.
    private static func rasterize(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.black.setFill()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func recolor(_ rep: NSBitmapImageRep,
                                shell: NSColor, aircraft: NSColor) -> NSBitmapImageRep? {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0,
              let alpha = alphaChannel(rep, width: width, height: height),
              let labels = label(alpha: alpha, width: width, height: height)
        else { return nil }

        guard let shellRGB = shell.usingColorSpace(.sRGB),
              let aircraftRGB = aircraft.usingColorSpace(.sRGB),
              let output = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let destination = output.bitmapData
        else { return nil }

        func channels(_ color: NSColor) -> (UInt8, UInt8, UInt8) {
            let r: Double = color.redComponent * 255
            let g: Double = color.greenComponent * 255
            let b: Double = color.blueComponent * 255
            return (UInt8(r.rounded()), UInt8(g.rounded()), UInt8(b.rounded()))
        }
        let shellChannels = channels(shellRGB)
        let aircraftChannels = channels(aircraftRGB)

        for index in 0..<(width * height) {
            let a = alpha[index]
            let isAircraft = labels[index] == 2
            let (r, g, b) = isAircraft ? aircraftChannels : shellChannels
            // Premultiplied, so the supplied antialiasing is preserved exactly.
            let scale = Double(a) / 255.0
            destination[index * 4 + 0] = UInt8(Double(r) * scale)
            destination[index * 4 + 1] = UInt8(Double(g) * scale)
            destination[index * 4 + 2] = UInt8(Double(b) * scale)
            destination[index * 4 + 3] = a
        }
        output.size = NSSize(width: Brand.Metric.statusGlyphSize,
                             height: Brand.Metric.statusGlyphSize)
        return output
    }

    private static func alphaChannel(_ rep: NSBitmapImageRep,
                                     width: Int, height: Int) -> [UInt8]? {
        var alpha = [UInt8](repeating: 0, count: width * height)
        if let data = rep.bitmapData, rep.samplesPerPixel == 4, !rep.isPlanar {
            let stride = rep.bytesPerRow
            for y in 0..<height {
                for x in 0..<width {
                    alpha[y * width + x] = data[y * stride + x * 4 + 3]
                }
            }
            return alpha
        }
        // Fall back to per-pixel reads for any layout we do not handle directly.
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                alpha[y * width + x] = UInt8(round(color.alphaComponent * 255))
            }
        }
        return alpha
    }

    /// Labels ink into 1 (shell) and 2 (aircraft). The supplied glyph is exactly
    /// two shapes, the aircraft being the smaller; anything else returns nil so
    /// the caller keeps the untouched template.
    private static func label(alpha: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let solid: UInt8 = 128
        var component = [Int](repeating: 0, count: width * height)
        var sizes: [Int] = [0]
        var next = 0

        for start in 0..<(width * height) where alpha[start] >= solid && component[start] == 0 {
            next += 1
            var count = 0
            var stack = [start]
            component[start] = next
            while let current = stack.popLast() {
                count += 1
                let x = current % width
                let y = current / width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighbour = ny * width + nx
                    if alpha[neighbour] >= solid && component[neighbour] == 0 {
                        component[neighbour] = next
                        stack.append(neighbour)
                    }
                }
            }
            sizes.append(count)
        }

        guard next == 2 else { return nil }
        let aircraftComponent = sizes[1] <= sizes[2] ? 1 : 2

        var labels = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) where component[index] != 0 {
            labels[index] = component[index] == aircraftComponent ? 2 : 1
        }

        // Antialiased edge pixels fall below the threshold and are unlabelled.
        // Grow the labels into them so the tint boundary follows the artwork.
        for _ in 0..<3 {
            var updates: [(Int, UInt8)] = []
            for index in 0..<(width * height)
            where alpha[index] > 0 && labels[index] == 0 {
                let x = index % width
                let y = index / width
                var votes: [UInt8: Int] = [:]
                for dx in -1...1 {
                    for dy in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let value = labels[ny * width + nx]
                        if value != 0 { votes[value, default: 0] += 1 }
                    }
                }
                if let winner = votes.max(by: { $0.value < $1.value })?.key {
                    updates.append((index, winner))
                }
            }
            if updates.isEmpty { break }
            for (index, value) in updates { labels[index] = value }
        }
        // Anything still unlabelled is a stray edge pixel; treat it as shell.
        for index in 0..<(width * height) where alpha[index] > 0 && labels[index] == 0 {
            labels[index] = 1
        }
        return labels
    }
}
