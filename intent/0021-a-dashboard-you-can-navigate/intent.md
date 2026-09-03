# 0021: a dashboard you can navigate

## How this came about

[0020](../0020-fleet-dashboard/intent.md) shipped a picture of the fleet and four
panels of statistics about it. What it did not have was a way to go anywhere. The
cluster drew every product and every environment at once, the panels always
described the whole account, and the only interaction was hovering a circle for
a tooltip. It answered "what does my fleet look like" and nothing after it.

Ten commits later it drills. The record of why is here rather than in 0020,
because most of it was decided while building rather than before, and rewriting
0020's spec to look prescient would be worth nothing.

The two questions that produced the last of it were asked out loud:

> maybe need a back button here ? otherwise how do we get to fleet level insights ?

Correct, and it was a dead end. Opening a host put its record on the Insights
tab, and the only way back out was the hub in the middle of the cluster, which is
on the Fleet tab. So the screen a person landed on had no exit on it.

> again add surrounding padding please, super tight around text

Also correct, and it was a bug rather than a taste call. See below.

## What was decided

- **One level at a time, not all of them at once.** Drawing products and
  environments together looked like a fleet and read like a hairball: at seven
  products with four environments each it is 35 circles with 28 labels competing
  for the same ring. Drilling shows one level, and the levels are the ones in
  `group_by`, so the picture and the menubar cascade cannot disagree.
- **The hub is the way back.** There was already a circle in the middle
  standing for the account. Making it the exit means back lives where the eye
  already is, and the picture needs no chrome around it.
- **A host is the last level down.** Below the last grouping key are instances,
  and opening one shows what `DescribeInstances` returned about it. This is the
  part that costs nothing and was being thrown away: Hangar parsed a third of
  that response and cached all of it.
- **Host circles are sized by the machine.** At group level a circle's area is
  its host count. At host level every circle would otherwise be identical, which
  wastes the one visual channel that is free. Size is taken from the instance
  type, so a `db` on an `8xlarge` beside an api tier on `large` reads without
  labels.
- **Counts, never advice.** Unchanged from 0020 and worth restating, because a
  host record is exactly where a tool starts wanting to tell you your instance
  is too small.

## The notice card

The padding note is not cosmetic. `NSStackView.fittingSize` reports its
cross-axis width without its own `edgeInsets`, so sizing the panel from that
measurement produced a card exactly as wide as its text column, and the 30 point
insets were compressed to nothing. The body then printed against the rounded
edge. Measured rather than guessed at: the fitting width came back 290 for a 290
point column that had asked for 60 points of padding around it.

The fix is to size the card from the text column plus the padding, both stated
as numbers, rather than from a measurement that silently leaves half of the
question out.

## Out of scope

- **A second AWS call.** Still the constraint from 0020. Everything on this
  screen is in the response Hangar already has, which is what lets the README
  say `ec2:DescribeInstances` and nothing else.
- **History per host.** The refresh history is a host count and a timestamp.
  Per-instance history over weeks is a different product and a different store;
  SQLite was measured for it and rejected, because the cache decodes in 1 ms
  against a 1,620 ms AWS refresh.
