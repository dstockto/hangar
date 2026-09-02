# 0014: a helper that hangs, a label that lied, and a screen that shows its work

## How this came about

Both defects were found by looking at the app, not the code. The first came out
of building screenshots for 0013: a demo fleet grouped by product alone listed
`web-1` three times. The second came out of the same demo, whose fake
`credential_process` slept, and which produced this:

> this looks like stuck ? for your screenshots

It was not stuck. It was waiting, forever, and saying nothing.

## The label that lied

`leafLabel` cut `product-env` off the front of every alias, on the assumption
that those were the two levels the row sat under. They are only the levels the
*default* config groups by. Group by product alone and the env is cut from the
label anyway, so `payments-prod-web-1`, `payments-stage-web-1` and
`payments-qa-web-1` all render as `web-1`, three identical rows pointing at three
different machines. On a prod box that is not a cosmetic bug.

It now takes the levels the menu is actually being built from. Everything else is
unchanged: the prefix is still only removed when the alias genuinely starts with
it, so grouping by a tag that is not part of the alias leaves the alias whole.

## The helper that hangs

`credential_process` is arbitrary code out of the user's own `~/.aws/config`, and
Hangar ran it with `readDataToEndOfFile`, which returns when the write end of the
pipe closes. A helper that never exits never closes it. The result: the fleet
refreshed forever, and the setup window sat on "Checking your setup…" over an
empty sheet, indefinitely, with no way to tell that from a crash.

Every other leg was already bounded, because `URLSession` has its own timeouts.
This one is now bounded too: 30 seconds, then `SIGTERM`, then `SIGKILL` two
seconds later, then a readable error. 30 rather than 5 because a helper that
waits for a hardware token to be touched is a legitimate slow case.

The wait is a poll on `isRunning` rather than a background reader, deliberately.
Reading on another thread would need shared mutable state across a concurrency
boundary, and this repo does not sign `@unchecked Sendable` waivers to make a
20-millisecond poll unnecessary.

## The screen that shows its work

Even bounded, 30 seconds of blank window is wrong. The setup screen now lists
all six steps from the first frame: finished ones as their real cards, the one in
flight with a spinner and the word `NOW`, the rest dimmed and slowly pulsing with
`WAIT`. The word is there because the brand kit does not let motion or colour
carry a state on its own, and the pulse is skipped when the system asks for
reduced motion.

Two smaller things on the same window, both asked for directly: **Source** left
the footer, because by the time this window is up the menubar item is already
there and linking to the repository is not what anyone wants from it, and
**Close** took its place. And the selected host row got its padding back: the
capsule was 8pt from the panel edge with the alias sitting one point above its
top edge, which read as cramped. 14pt at the sides, and the two text baselines
two points lower so the highlight has air above and below them.
