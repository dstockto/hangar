# Intent: ship the layered app icon

## Problem

The app icon's source of truth is five layered SVGs plus an appearance manifest,
designed to be assembled in Icon Composer so the icon responds correctly to Dark,
Clear and tinted appearances. That assembly has not been done. The bundle
currently ships a flattened `.icns` rendered from `preview-default-1024.png`, a
file the brand kit explicitly labels a review reference rather than a rendering
source.

The result is an icon that is correct in the default appearance and merely
acceptable in the others, on a product whose pitch is that it is precisely native.

## Outcome

`Hangar.icon` exists, is compiled into the bundle, and the fallback path in
`scripts/bundle.sh` becomes dead code that can be removed.

## Constraints

- Icon Composer is GUI-only: no command line, no scriptable dictionary. This step
  cannot be automated, which is why it has stayed undone.
- Compiling a layered `.icon` needs Xcode's icon toolchain, so `bundle.sh` gains
  a real dependency on Xcode for the icon step. The Swift build must still need
  only the Command Line Tools.
- The layered SVGs stay the source of truth and are not deleted.

## Acceptance

- The icon reads correctly at 16 pt in all four appearances, with the
  aircraft-to-post gaps open and the gable not filled.
- `make verify-assets` still passes.
- The preview-derived fallback is removed from `scripts/bundle.sh`.

## Out of scope

Redrawing any layer. The geometry is settled.

## Status

Open. Assembly steps are in
[app/Resources/app-icon/BUILD.md](../../app/Resources/app-icon/BUILD.md).
