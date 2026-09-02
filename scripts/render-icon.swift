#!/usr/bin/env swift
// Flattens the layered icon sources into the review PNGs the bundle falls back
// to. Icon Composer is GUI-only, so this cannot produce the layered .icon; it
// can and does keep the flattened artwork reproducible from the same SVGs,
// which beats a PNG nobody can regenerate.
//
// Usage: swift scripts/render-icon.swift <app-icon-dir>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <app-icon-dir>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1])
let layers = root.appendingPathComponent("layers")

struct Appearance {
    let name: String
    /// Per-layer fill overrides, keyed by the layer file's stem.
    let fills: [String: String]
}

let order = ["field", "aperture", "hangar-shell", "aircraft", "threshold"]

let appearances = [
    Appearance(name: "default", fills: [:]),
    Appearance(name: "dark", fills: [
        "field": "#0E1115", "aperture": "#17435F", "hangar-shell": "#39424B",
        "aircraft": "#57B9FF", "threshold": "#F3F6F8",
    ]),
]

/// Swaps the first fill in a layer's markup, which is all these sources carry.
func recolour(_ svg: String, to colour: String?) -> String {
    guard let colour else { return svg }
    // Two hashes: the pattern itself contains a quote followed by a hash.
    let pattern = ##"fill="#[0-9A-Fa-f]{6}""##
    guard let range = svg.range(of: pattern, options: .regularExpression)
    else { return svg }
    return svg.replacingCharacters(in: range, with: "fill=\"\(colour)\"")
}

func render(_ appearance: Appearance, size: Int) throws -> Data {
    // An explicit sRGB bitmap at exactly the requested pixel size. Drawing into
    // an NSImage instead picks up the main display's backing scale and colour
    // space, which silently produced 2048px files with shifted blues.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else {
        throw NSError(domain: "render-icon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "could not allocate the bitmap",
        ])
    }
    bitmap.size = NSSize(width: size, height: size)
    let srgb = bitmap.retagging(with: .sRGB) ?? bitmap

    guard let context = NSGraphicsContext(bitmapImageRep: srgb) else {
        throw NSError(domain: "render-icon", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "could not make a context",
        ])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    for name in order {
        let url = layers.appendingPathComponent("\(name).svg")
        let markup = recolour(try String(contentsOf: url, encoding: .utf8),
                              to: appearance.fills[name])
        guard let layer = NSImage(data: Data(markup.utf8)) else {
            NSGraphicsContext.restoreGraphicsState()
            throw NSError(domain: "render-icon", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "could not rasterize \(name).svg",
            ])
        }
        layer.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = srgb.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-icon", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "could not encode PNG",
        ])
    }
    return png
}

for appearance in appearances {
    for size in [1024, 32, 16] {
        let data = try render(appearance, size: size)
        let out = root.appendingPathComponent("preview-\(appearance.name)-\(size).png")
        try data.write(to: out)
        print("wrote \(out.lastPathComponent)")
    }
}
