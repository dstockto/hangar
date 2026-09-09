# 0029: typing more narrows

## How this came about

Searching a fleet of seven imported ssh_config hosts for the Raspberry Pi:

```
$ hangar ssh rasp
hangar: 2 hosts match "rasp". Which one?
  1  raspberrypi4.local  raspberrypi4   raspberrypi4.local
  2  brotherspaint.com   brotherspaint  brotherspaint.com
```

`rasp` is not a subsequence of `brotherspaint.com`, nor of `brotherspaint`. The
question was where the second row could possibly have come from.

## What was actually true

`SearchEntry.metadata` joined four fields into one haystack. `SSHConfigImport`
takes both `product` and `role` from the host name, so two of the four held the
same string and the value appeared twice:

```
metadata "brotherspaint brotherspaint"
```

A subsequence match could start in one copy and finish in the next, taking `r`
and `a` from the first and `s` and `p` from the second:

```
b[r]othersp[a]int brother[s][p]aint
```

That is worse than a stray result. Duplication does not change what short queries
match, so `ra` matched before and matches now. It only lets *longer* queries
match what they otherwise could not, which defeats the one thing a person is
doing when they keep typing. On this fleet `ra` gave three hosts, `ras` gave two,
and `rasp` still gave two.

Not an ssh_config problem. Import guarantees the collision, but an EC2 host
tagged `product=web` with `Name=web` had the same haystack, so `web prod web`
matched `wpb`. The condition is "two fields hold the same string", which import
guarantees and EC2 merely permits. Keying the fix on where the host came from
would have fixed the symptom.

Nothing covered it. No test built a fleet where two of the four fields held the
same value, at either level: not one `SearchEntry`, and not a fleet through
`FleetIndex`, which is where the reported counts came from.

## Decided

Deduplicate the components before joining, preserving order. Cross-field search
is the point of the field and is untouched: `["payments", "prod", "web"]` stays
exactly as it is, and only the repeated value collapses. `ra` still gives three,
`ras` and `rasp` now give one.

Deduplicated on the lowered bytes the search actually compares, not on the exact
string and not on a Unicode case fold. Both of the other two are wrong, in
opposite directions:

- The exact string leaves the class half open. The haystack is lowercased before
  it is searched, so `product=Web` with `Name=web` doubled it just as surely as
  two identical spellings did.
- A Unicode case fold, which is where this first landed, is **worse than the bug**.
  `Fuzzy.lowered` folds ASCII only, so `Über` and `über` are different bytes to
  the search. `caseInsensitiveCompare` calls them equal, collapses them to one
  copy, and then the lowercase spelling is in no field at all: typing `über`
  finds nothing. A phantom match is annoying, a missing host is a broken tool.

So the dedupe key is `Fuzzy.lowered(field)`, which is exactly as wide as the
haystack and no wider. `testDedupeIsNeverWiderThanTheSearch` pins that boundary,
and it fails against the case-folding version.

## The open question, and why it stays open

Dedupe does not stop one token spanning two *distinct* fields. `payments prod
web` still matches `pdw`, one letter from each, matching none of the three alone.
That is the same shape of failure in a milder form, and it is also the intended
acronym behaviour: `Fuzzy.score` rewards word-boundary hits, and the docblock's
own example is `ppw` finding `payments-prod-web`.

The principled fix would be to score each field separately and take the best,
which is what `SearchEntry.score` already does one level up across alias,
hostname and metadata. **Left alone deliberately.** It would drop `ppw`-style
matches on real fleets, and it would also drop space-less queries that work
today: `paymentsprod` matches `payments prod` now because subsequence skips the
space, and per-field scoring would not. That is a product decision about what
search is for, not a bug, so it does not ride along with a bug fix.

## What proves it

`FleetIndexTests.testTypingMoreNarrowsTheFleet` rebuilds the reported fleet of
three imported hosts and asserts the counts. Against the old join it reports `ra`
three, `ras` two, `rasp` two, which is the report; against the fix it reports
three, one, one. The `DuplicateMetadataSearchTests` cases pin the haystack itself,
including the EC2 collision the issue used to show this is not an import problem.

## Reach

`Fuzzy.swift` reaches both front ends through `FleetIndex`, so the panel
(`Panel.swift:363`) and `hangar` (`main.swift:230`) behaved identically before
and behave identically after. That is why this got its own change rather than
riding along in the command line stack, which never touched this file.
