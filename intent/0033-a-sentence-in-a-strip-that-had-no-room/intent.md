# 0033: a sentence in a strip that had no room

## How this came about

A screenshot of the panel with an expired SSO session. The bottom line was
unreadable: two strings drawn on top of each other, the first letter clipped off
the left edge, and the tail of the sentence rendering perfectly. Reading it
closely, `\u{21A9} Connect    \u{2318}\u{21A9} Copy    \u{2318}E Edit` was
superimposed on `Your SSO session has expired. Run aws`, and from roughly the
middle of the strip onward `sso login --profile aws-developer-collect, then
retry.` was clean.

That split is the whole diagnosis. The garbling stops exactly where the hints
label ends.

## What was actually true

`FooterView` puts three things on one line: a stale-cache glyph and a `hints`
label pinned to the leading edge, and a right-aligned `status` label pinned to
the trailing edge. All three share a `centerYAnchor`. Nothing constrained
`status.leading` against `hints.trailing`, and neither label truncated, so the
two were free to occupy the same points and AppKit obligingly drew both.

Measured in the real font, `.monospacedSystemFont(ofSize: 11)`:

| status text | width | starts at x |
|---|---|---|
| `12 of 249    updated 2 minutes ago` | 231.2 | 392.8 |
| `Refreshing…` | 74.8 | 549.2 |
| `Your SSO session has expired. Run aws sso login --profile aws-developer-collect, then retry.` | 625.6 | **-1.6** |

The hints occupy 38 to 248.4. The normal cases start well right of that and the
overlap never happens, which is why this survived. The failure case is 625.6
points wide in a 640 point panel, so right-aligning it starts it at -1.6: through
the whole hints label and off the left edge of the panel.

The message itself is not the bug. `CredentialAdvice.Advice.message` is
documented as "One sentence for the menu or the setup check", and the menu and
the setup check both have room for a sentence. The footer took that field and put
it in a strip that already spends 210 of its points on hints, and the panel is
resizable down to 520, so the room is not even a constant.

## What was decided

**A failure has two lengths, and one value carries both.** `Advice` gains a
`summary`, a few words naming the cause, unpunctuated because it is a label
rather than prose. `FleetStore.Status.failed` stops carrying a bare `String` and
carries a `Failure` holding `summary` and `detail` together, so the short form
cannot drift from the long one and no caller has to decide which it is holding.
The menu, the notification and the menubar tooltip take `detail`; only the footer
takes `summary`.

That change caught a silent bug on the way through. One consumer interpolated the
old `String` into a tooltip, and string interpolation accepts any type, so it
compiled unchanged and would have printed the struct.

**A summary that embeds a profile name is not a summary.** The first draft wrote
`Profile \(name) has no credentials` and `Source profile \(source) expired`. A
profile name has no length limit, so neither is bounded, and the test written to
assert they fit is what found it. They are now `No usable credentials` and
`Source profile expired`; the name is still in the sentence, which the tooltip
and the menu both carry.

**Arithmetic decides the fit, not a fitting size.** `drawStatus` computes the room
left beside the hints from the numbers: the leading inset, the glyph, the hints'
own intrinsic width, and the two gaps. This is mistake 15 again, where a stack's
`fittingSize` left its own insets out of the width and 30 points of padding a side
became none. It runs from `layout()` as well as from `update`, because the panel
resizes between 520 and 760, guarded on the width having actually changed so that
setting the label inside `layout()` cannot start a loop.

**`Truncation.fitting` is the backstop, not the mechanism.** Every hand-written
summary fits at the panel's minimum width with room to spare, verified against the
real font at 520, 640 and 760. Truncation exists for the fallback case, a raw
error from AWS that nobody wrote a summary for, where `firstSentence` shortens
what it can and the strip cuts whatever is left.

**The sentence had to keep a way out.** Truncating it to fit would have eaten
`aws sso login --profile …`, which is the actionable half and the thing mistake 2
exists to protect. It goes to the tooltip, on the whole strip rather than on the
few words still visible, and the menu's Copy Login Command is untouched.

**The strip still names the set it counted.** A failure shows `0 of 0` beside the
cause rather than replacing the count with prose, which is mistake 26.

`product-a-failure-the-footer-can-say` guards both halves: no summary over 25
characters, and none containing an interpolation. It was watched failing against
a planted long summary, a planted interpolated one, and the summaries being
renamed out from under it, the last being the positive control that stops a
broken grep from reading as a pass. That is mistake 16.
