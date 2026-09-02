# Design

Source assets and the brand specification. **Nothing here is a build input.**

The app builds from `app/Resources/HangarAssets.xcassets`, which is where the
compiled colours and glyphs come from. The files here are the originals those were
cut from, plus the specification that governs them. Editing something here does
not change the app.

```
brand/Brand_Kit.md            the specification: palette, geometry, type, copy deck
brand/colors.json             the palette as data
brand/HangarDesignTokens.swift  the palette as Swift, supplied for reference and
                              not compiled. The app reads named colours from the
                              asset catalog instead, so a missing asset is a
                              build failure rather than a silent fallback.
brand/hangar-status-*.svg     menubar glyph, primary plus two alternates
brand/HangarStatus*.png       raster menubar templates, 1x and 2x
brand/wordmark/               the wordmark lockup, all four variants
brand/MANIFEST.sha256         checksums for everything in brand/
brand/wordmark/MANIFEST.sha256  checksums for the wordmark package
```

Verify a package has not drifted:

```sh
cd design/brand && shasum -a 256 -c MANIFEST.sha256
cd design/brand/wordmark && shasum -a 256 -c MANIFEST.sha256
```

Only the primary menubar glyph is bundled. The two alternates are kept for future
evaluation, which is why they appear here and not in the asset catalog.

The app icon's layered sources are not here; they live beside the manifest that
describes their assembly, in `app/Resources/app-icon/`.
