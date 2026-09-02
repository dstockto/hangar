# Plan: landing page

1. Capture the current production site first, at five viewports, into
   `.site-review/before/`. Record the defects before changing anything.
2. Diagnose the deployment. `gh api repos/:owner/:repo/pages` reports the source;
   fetching `assets/*` proves what is actually served.
3. `site/styles.css`: tokens for both appearances, then components.
4. `site/index.html`: semantic structure, the panel representation, the sections.
5. `site/app.js`: mobile menu and copy buttons only.
6. `site/assets/og.png`: generated from the real app icon by a small AppKit
   script, so the social card uses the supplied artwork rather than a redraw.
7. `.github/workflows/pages.yml`: upload `site/` as an artifact, with a pre-flight
   check for absolute asset paths and stray localhost URLs.
8. Screenshot, critique in writing, refine, screenshot again.

## Verification

Serve locally under a `/hangar/` prefix so the base path is exercised as in
production. Then, in the browser: heading order, anchor targets, absolute paths,
alt text, tap target heights, horizontal overflow at 320 px, console messages,
network requests, and the mobile menu's focus behaviour.

## Findings from the first pass

Written up in `.site-review/after-v1/critique.md`. Three defects fixed: a dead
band above the hero, `text-transform` rendering "MACOS", and an accent glow on the
primary button that read as a template.
