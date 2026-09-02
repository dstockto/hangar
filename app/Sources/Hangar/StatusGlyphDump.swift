import AppKit

/// Debug helper behind --dump-status-glyph. Renders each menubar state to PNG so
/// the shape separation and health tint can be checked directly.
enum StatusGlyphDump {
    @MainActor
    static func run(directory: String) -> Bool {
        let states: [(String, NSColor, NSColor)] = [
            ("healthy-dark-menubar", .white, Brand.Color.stateRunning),
            ("healthy-light-menubar", .black, Brand.Color.stateRunning),
        ]
        var ok = true
        for (name, shell, aircraft) in states {
            guard let image = StatusGlyph.twoTone(shell: shell, aircraft: aircraft) else {
                let source = NSImage(named: "HangarStatusTemplate")
                let reps = (source?.representations ?? []).map {
                    "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)"
                }
                print("FAIL could not compose \(name); source reps: \(reps)")
                ok = false
                continue
            }
            ok = write(image, to: "\(directory)/\(name).png", scale: 2) && ok
            let reps = image.representations
                .map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ",")
            print("\(name): template=\(image.isTemplate) "
                  + "size=\(Int(image.size.width))x\(Int(image.size.height))pt reps=\(reps)")
        }
        if let plain = StatusGlyph.plain() {
            ok = write(plain, to: "\(directory)/stale-template.png", scale: 2) && ok
            print("stale-template: template=\(plain.isTemplate) "
                  + "size=\(Int(plain.size.width))x\(Int(plain.size.height))pt")
        }
        return ok
    }

    private static func write(_ image: NSImage, to path: String, scale: Int) -> Bool {
        let pixels = Int(image.size.width) * scale
        // The composed glyphs carry bitmaps we made ourselves, but an image straight
        // out of the asset catalog hands back no NSBitmapImageRep at all, so it has
        // to be drawn into one first.
        let existing = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first { $0.pixelsWide == pixels }
            ?? image.representations.compactMap { $0 as? NSBitmapImageRep }.last
        guard let rep = existing ?? rasterize(image, pixels: pixels),
              let data = rep.representation(using: .png, properties: [:])
        else {
            print("FAIL rendering \(path)")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            print("FAIL writing \(path): \(error.localizedDescription)")
            return false
        }
    }

    private static func rasterize(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard pixels > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
