# Spec: landing page

## Location and deployment

The page lives in `site/`, separate from documentation. Legacy Pages can only
publish the repository root or `docs/`, so `site/` is deployed by
`.github/workflows/pages.yml` as a static artifact, which also bypasses Jekyll
entirely and is the actual fix for the rendered-README problem.

Requires one repository setting: Pages source set to GitHub Actions.

## Structure

Sticky navigation, then: hero, proof strip, before-and-after, six features,
ssh_config interoperability with a copy button, security, install, documentation
links, final call to action, footer.

## Hero

Eyebrow "NATIVE macOS · SIGNED AND NOTARIZED", headline "Your fleet, one keystroke
away.", the supporting sentence, Download and GitHub actions, and a fine line
stating macOS 14+, no server, no account, no runtime dependencies.

The right column is a representation of the floating panel, drawn in HTML and CSS
from the brand kit's geometry: 18 px radius, 48 px rows, monospaced aliases, a
selection capsule, a production rail and PROD badge, and the footer hints. It is
labelled an illustration, not a screenshot, and is `aria-hidden` with a text
description beside it so a screen reader gets the meaning rather than fake rows.

## Appearance

Brand tokens for both appearances via `prefers-color-scheme`. No theme switcher:
it would need storage or accept a flash of the wrong theme.

## Motion

None beyond a caret. An earlier draft typed the query out; it was cut because the
brief warns off typing gimmicks, a composed panel says more per pixel, and the
reset-to-empty flashed the finished state first.

## Acceptance

No horizontal scroll from 320 px up. No raw Markdown. One H1, correct heading
order. Mobile menu opens, closes on Escape, restores focus. No tap target under
44 px on a coarse pointer. Zero console messages and zero external requests.
