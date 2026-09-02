# Remaining manual step: assemble Hangar.icon in Icon Composer

**Status: not done.** The layered app icon has *not* been created. The bundle
currently ships a flattened icns built from `preview-default-1024.png`, which the
brand kit explicitly labels a review reference rather than a rendering source.

## Why this cannot be automated here

Icon Composer ships inside Xcode at
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app` and is
GUI-only. It exposes no command-line interface and no scriptable dictionary, so
a `.icon` document cannot be produced from a terminal. `iconutil` builds legacy
`.icns` from flat PNGs and cannot author the layered, appearance-annotated
format that Liquid Glass, tinting, and the Clear appearance require.

Everything needed is already in the repository:

```
app/Resources/app-icon/
├── layers/field.svg           1024 x 1024, full canvas
├── layers/aperture.svg
├── layers/hangar-shell.svg
├── layers/aircraft.svg
├── layers/threshold.svg
├── IconComposer_Manifest.json  fills and material values per layer
└── BUILD.md                    the supplied assembly instructions
```

## Steps

1. Open `/Applications/Xcode.app/Contents/Applications/Icon Composer.app`.
2. New macOS icon document, 1024 x 1024 source grid.
3. Import all five SVGs from `app/Resources/app-icon/layers/` **at full canvas
   size**. Do not trim bounds.
4. Order them back to front exactly: `field`, `aperture`, `hangar-shell`,
   `aircraft`, `threshold`.
5. Apply per-layer fills and materials from `IconComposer_Manifest.json`:

   | Layer | Default | Dark | Mono | Material |
   |---|---|---|---|---|
   | field | `#E7EDF1` | `#0E1115` | 12% white | Glass: low translucency, low refraction, automatic inner specular |
   | aperture | `#CBE9FF` | `#163A52` | 24% white | Glass: medium translucency, low blur, low refraction, inside specular, clear opacity >= 62% |
   | hangar-shell | `#273039` | `#39424B` | 52% white | Opaque, automatic outside specular only |
   | aircraft | `#006EAD` | `#57B9FF` | 100% white | Opaque, subtle automatic outside specular |
   | threshold | `#15191D` at 72% | `#F3F6F8` at 28% | 72% white | Glass: low translucency, low refraction, no shadow |

6. Keep `hangar-shell` and `aircraft` opaque in Default, Dark, Clear, and Mono.
   Author no shadows and no specular highlights into the SVGs; Icon Composer
   owns the enclosure, refraction, specular response, and platform shadow.
7. Preview at 16, 32, 64, 128, 256, 512, and 1024 pt in Default, Dark, Clear,
   and tinted/Mono.
8. **Reject the build** if, at 16 pt, the aircraft-to-post gaps close or the
   gable becomes a filled triangle.
9. Save as `Hangar.icon` in `app/Resources/app-icon/`.

## After saving

`make bundle` already checks for that file:

```make
icon:
	@if [ -f $(ICONSRC)/Hangar.icon ]; then \
		echo "Hangar.icon present; Icon Composer output takes precedence"; \
```

Once `Hangar.icon` exists, the temporary preview-derived icns is skipped. The
`.icon` then needs compiling into the bundle, which is the one part of the build
that will need Xcode's icon toolchain rather than the hand-rolled bundle step;
wire it into the `icon` target at that point.

Do not delete the layered SVG sources. They are the icon's source of truth.
