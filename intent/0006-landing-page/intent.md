# 0006: a landing page that was never being served

## How this came about

> make a dedicated marketing page that lands at
> https://goriparthi.github.io/hangar/ ... use screenshots, make it rich

with a list of confirmed defects attached: raw Markdown in the hero, no real
call to action, a page indistinguishable from a rendered README.

The instruction to capture the production site *before changing anything* is what
made this tractable, because the defects turned out to be symptoms of something
the brief had not guessed at.

## What the capture revealed

The hero showed literal `# Hangar`, `**Spotlight for your SSH hosts.**` and a
bracketed Download link with its raw URL, because the README's hero sits inside a
`<div align="center">` block and Markdown does not parse inside one.

But the page being rendered was `README.md`, not the hand-written
`docs/index.html` that had existed for days. Pages was building the repository
root through Jekyll v3.10, which injected its own `<head>`, its own SEO tags and
a Google Analytics stub. `docs/assets/*` returned 404: the page had never been
served at all.

So the visible symptom was Markdown leaking, and the actual fault was a
deployment serving a different file than anyone thought.

## The structural decision

Asked mid-build:

> instead of pushing this into docs, shouldn't this be cleanly done in site/ or
> similar? so we don't mix docs and marketing pages

Correct, and it resolved the deployment problem too. Legacy Pages can only publish
the repository root or `docs/`, so `site/` forces an Actions deployment, which
uploads the directory as a static artifact and bypasses Jekyll entirely. One
change fixed the layout and the root cause.

## What was cut and why

An earlier draft typed the search query out to narrow 249 hosts to three. It was
removed: the brief warns off typing gimmicks, a composed panel says more per
pixel than a half-typed one, and resetting the query to empty on load flashed the
finished state first. The counters state the same fact statically, and a static
panel cannot shift layout.

No theme switcher, for the same class of reason: it needs either storage or a
flash of the wrong theme.

## The tradeoff taken knowingly

The hero panel is drawn in HTML and CSS, not a screenshot, and is labelled as an
illustration. Real screenshots would publish this fleet's internal hostnames and
product names, which the brief prohibits. Genuine screenshots need a synthetic
demo fleet, which is worth doing and was not done here.

## Proof, and self-critique

Screenshots at five viewports in both appearances, then a written critique of my
own first pass in `.site-review/after-v1/critique.md`, then a second pass. Three
defects I had introduced and had to be shown by the screenshots to see: a 340 px
dead band above the hero, `text-transform` rendering "MACOS", and an accent glow
on the primary button that read as a bought template.

Verified in the browser rather than asserted: no horizontal scroll from 320 px,
every anchor resolving, one H1 in correct order, the mobile menu returning focus
on Escape, no tap target under 44 px on a coarse pointer, zero console messages
and zero external requests.
