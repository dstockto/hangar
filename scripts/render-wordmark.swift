#!/usr/bin/env swift
// Rasterises the wordmark lockups into their @2x PNG fallbacks, so the PNGs in
// the brand kit stay reproducible from the SVGs beside them rather than being
// artifacts nobody can rebuild.
//
// Usage: swift scripts/render-wordmark.swift <wordmark-dir>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: render-wordmark.swift <wordmark-dir>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1])

/// The lockup is 420x96 in user units; the kit ships it at 2x.
let scale = 2
let width = 420 * scale
let height = 96 * scale

func render(_ svg: URL, to png: URL) throws {
    let data = try Data(contentsOf: svg)
    guard let image = NSImage(data: data) else {
        throw NSError(domain: "wordmark", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not read \(svg.lastPathComponent)"])
    }
    // An explicit sRGB bitmap at exactly the requested pixel size, with alpha.
    // Drawing into an NSImage instead picks up the display's backing scale, and
    // these are template marks: the background has to stay transparent.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        throw NSError(domain: "wordmark", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not make a bitmap"])
    }
    bitmap.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "wordmark", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "could not make a context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let out = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "wordmark", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "could not encode a PNG"])
    }
    try out.write(to: png)
    print("  \(png.lastPathComponent)  \(width)x\(height)")
}

let names = ["hangar-wordmark-light", "hangar-wordmark-dark",
             "hangar-wordmark-mono-black", "hangar-wordmark-mono-white"]
for name in names {
    let svg = root.appendingPathComponent("\(name).svg")
    guard FileManager.default.fileExists(atPath: svg.path) else { continue }
    try render(svg, to: root.appendingPathComponent("\(name)@2x.png"))
}
