# 0009: let the fleet tell us its own tag names

## How this came about

> how can we make this work for any SREs who use EC2s? can we on the onboarding
> setup screen on first launch show tags that they can pick for this? curious how
> we can make it work cleanly for anyone outside my setup

0003 made the tag names configurable, which moved the failure from "impossible"
to "possible if you find the right JSON key and know what to put in it". That is
still a wall on first launch, and the person hitting it has just downloaded the
app and has no reason to persist.

The observation in the question is the whole design: by the time the setup screen
runs, Hangar has already fetched the fleet. It knows exactly which tag keys exist
and what they contain. Guessing is unnecessary.

## What the defaults do and do not cover

Worth stating precisely, because it is the case for the picker. Against a fleet
tagged `BusinessUnit` / `DeployTier` / `Function`:

- `Function` resolves, because `function` is already in the role candidates.
- `BusinessUnit` and `DeployTier` resolve to nothing.

So the fleet is not *ungrouped*, which means the setup check's warning does not
even fire, and yet both groupings that build the menu are empty and every host in
a tier collapses to its bare role. A partial match is the worst case: it looks
like it is working.

## The design questions

**Which tags are worth offering?** All of them, ranked, minus `aws:` managed ones,
which are real and useless for grouping. Ranking is by coverage first, then by a
grouping score that peaks for keys carried by most of the fleet and taking more
than one value but far fewer than one per host. A key with one value groups
nothing; a key with as many values as hosts is an identifier. Both are shown, and
both sort below the useful ones.

**How does a person recognise a key they did not choose?** By its contents, so
each entry carries how many hosts have it, how many distinct values it takes, and
two real values.

**What should the picker show when it opens?** The truth: whatever the current
mapping actually resolves against this fleet, using the key as AWS spells it. When
nothing resolves, a suggestion, but only when a key's name plainly reads as that
idea. A wrong suggestion presented confidently is worse than an empty picker,
because it gets accepted.

**When does a choice take effect?** Immediately, and without a refresh. The tags
are already in hand, so choosing re-normalizes, rebuilds the aliases, rewrites the
ssh include and re-runs the checks. The point is to see it work, not to be told
to restart.

**Where does the catalog come from?** The tags as AWS returned them, captured
before normalization. After normalization the canonical keys are present whether
the fleet uses them or not, and offering someone `product` when they have never
used it is exactly the confident wrong suggestion this is trying to avoid. It is
persisted with the cache so the screen works before the first refresh completes.

## Also

"Not used" is a legitimate choice, not an error state. Not every fleet has a
second grouping, and forcing one produces meaningless menu levels.

## Proof

`TagCatalogTests`, against a fleet using none of Hangar's names: discovery and
counts, AWS-managed tags excluded, samples, an identifier-like key scoring below
a grouping key, suggestions offered only where the name reads as related, and the
whole first-launch flow ending in 30 hosts with working aliases and not one named
by its instance id.
