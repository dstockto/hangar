# 0019: a bigger, brighter icon, rendered from source

## How this came about

> make app icon slightly larger within the boundaries ? maybe slightly colorful ?

The artwork filled 66% of the canvas width, which is timid for a macOS icon, and
the palette was a grey field behind a muted blue. Both are fair notes.

## What was in the way

The shipped icon is a flattened `.icns` built from `preview-default-1024.png`,
and that PNG was a hand-made artifact: `BUILD.md` called it a review reference,
Icon Composer is GUI-only, and nothing in the repository could regenerate it. So
"make the icon bigger" meant "edit a binary nobody can rebuild", which is how
assets drift away from their sources.

So the first change is `make icon`: `scripts/render-icon.swift` composites the
five layer SVGs into every preview at exact pixel sizes in sRGB. Rendering the
untouched sources first reproduced the committed artwork, which is what made the
renderer trustworthy enough to change the art with.

Two things it got wrong on the way, both worth remembering: drawing into an
`NSImage` picks up the main display's backing scale, so a 1024 request wrote a
2048 file; and without an explicit sRGB bitmap the blues shifted. An explicit
`NSBitmapImageRep` fixes both.

## The change

- **1.16x**, about the artwork's own centre, so it fills about 78% of the width
  and still clears the corner mask by a wide margin at every size. It is applied
  as a transform inside each layer SVG rather than by rewriting coordinates, so
  an Icon Composer import at full canvas size lands in the same place.
- **A little more colour**: field `#E7EDF1` to `#E8F1F9`, aperture `#CBE9FF` to
  `#B8E0FF`, aircraft `#006EAD` to `#0A80CE`, shell `#273039` to `#222B36`. The
  aircraft against the aperture stays above 3:1, which is the bar for a graphic.

The layered `.icon` is still unbuilt, so the glass materials and the tinted and
clear appearances are still ahead of us. That remains
[0007](../0007-layered-app-icon/intent.md).
