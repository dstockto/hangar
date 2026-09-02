# Icon Composer Assembly

1. Create a new macOS icon document with a 1024 × 1024 source grid.
2. Import every SVG from `layers/` at full canvas size. Do not trim bounds.
3. Order layers: `field`, `aperture`, `hangar-shell`, `aircraft`, `threshold`.
4. Apply the appearance fills and material properties from `IconComposer_Manifest.json`.
5. Keep `hangar-shell` and `aircraft` opaque in Default, Dark, Clear, and Mono.
6. Give glass treatment only to `field`, `aperture`, and `threshold`; do not author shadows into SVGs.
7. Preview at 16, 32, 64, 128, 256, 512, and 1024 pt in Default, Dark, Clear, and tinted/Mono.
8. At 16 pt, reject the build if the aircraft-to-post gaps close or the gable becomes a filled triangle.
9. Save the Icon Composer document as `Hangar.icon` beside this file and add it to the Xcode target.

The SVG fills represent the Default appearance only. Icon Composer appearance annotations override them in Dark and Mono modes.

