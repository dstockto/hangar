# Intent: a landing page, not a rendered README

## Problem

GitHub Pages was serving the repository root through Jekyll, which rendered
`README.md` under a default theme. The hero's `<div align="center">` block
suppressed Markdown parsing, so the page opened with literal `# Hangar`,
`**Spotlight for your SSH hosts.**` and a bracketed Download link with its raw
URL beside it, all as visible text. The hand-written page at `docs/index.html` was never served at all; its
assets returned 404.

The result looked like an unfinished repository, which is the opposite of the
claim the product makes about itself.

## Outcome

A landing page that explains the product in five seconds, looks like a native
macOS utility, and is deployed deterministically.

## Constraints

- No framework, no CDN fonts, no analytics, no cookie banner.
- Must work under the `/hangar/` base path.
- Dark appearance is primary; light must look intentional.
- No invented adoption numbers, testimonials or star counts.
- No real infrastructure names, internal domains or addresses.
- The README keeps the deep technical detail; the page links to it.

## Out of scope

Documentation hosting. The README and the Markdown files stay the reference.
