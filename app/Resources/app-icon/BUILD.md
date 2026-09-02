# Assembling the app icon

The icon's source of truth is the five layered SVGs in `layers/`. They are
assembled into `Hangar.icon` with Icon Composer, which is GUI-only: it ships
inside Xcode at `/Applications/Xcode.app/Contents/Applications/Icon Composer.app`
and exposes no command line and no scriptable dictionary, so this one step cannot
be automated from the build. `iconutil` builds legacy `.icns` from flat PNGs and
cannot author the layered, appearance-annotated format that tinting and the Clear
appearance need.

**Current state:** `Hangar.icon` does not exist yet, so `scripts/bundle.sh` falls
back to a flattened `.icns` rendered from `preview-default-1024.png`. That PNG is
no longer hand-made: `make icon` regenerates every preview from these same SVGs
via `scripts/render-icon.swift`, at exact pixel sizes in sRGB. The shipped icon
is still provisional, because a flattened render cannot carry the glass
materials or the tinted and clear appearances that only Icon Composer authors.

The artwork sits at 1.16x inside the canvas, applied as a transform within each
layer SVG rather than by moving coordinates, so an Icon Composer import at full
canvas size lands in the same place. Tracked as
[intent/0007-layered-app-icon](../../../intent/0007-layered-app-icon/intent.md).

## Steps

1. New macOS icon document, 1024 x 1024 source grid.
2. Import all five SVGs from `layers/` **at full canvas size**. Do not trim
   bounds.
3. Order them back to front exactly: `field`, `aperture`, `hangar-shell`,
   `aircraft`, `threshold`.
4. Apply the per-layer fills and materials from `IconComposer_Manifest.json`:

   | Layer | Default | Dark | Mono | Material |
   |---|---|---|---|---|
   | field | `#E8F1F9` | `#0E1115` | 12% white | Glass: low translucency, low refraction, automatic inner specular |
   | aperture | `#B8E0FF` | `#17435F` | 24% white | Glass: medium translucency, low blur, low refraction, inside specular, clear opacity >= 62% |
   | hangar-shell | `#222B36` | `#39424B` | 52% white | Opaque, automatic outside specular only |
   | aircraft | `#006EAD` | `#57B9FF` | 100% white | Opaque, subtle automatic outside specular |
   | threshold | `#15191D` at 72% | `#F3F6F8` at 28% | 72% white | Glass: low translucency, low refraction, no shadow |

5. Keep `hangar-shell` and `aircraft` opaque in Default, Dark, Clear and Mono.
   Give glass treatment only to `field`, `aperture` and `threshold`.
6. Author no shadows and no specular highlights into the SVGs. Icon Composer owns
   the enclosure, refraction, specular response and platform shadow.
7. Preview at 16, 32, 64, 128, 256, 512 and 1024 pt in Default, Dark, Clear and
   tinted/Mono.
8. **Reject the result** if, at 16 pt, the aircraft-to-post gaps close or the
   gable becomes a filled triangle.
9. Save as `Hangar.icon` beside this file.

The SVG fills are the Default appearance only. Icon Composer's appearance
annotations override them in Dark and Mono.

## Wiring it into the build

`scripts/bundle.sh` already checks for `Hangar.icon` and prefers it over the
fallback. Compiling a layered `.icon` into the bundle needs Xcode's icon
toolchain rather than the hand-rolled bundle step, so that part has to be added
to the script at the same time.

Do not delete the layered SVG sources.
