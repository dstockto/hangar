# 0030: typing more narrows

## How this came about

Searching a fleet of seven imported ssh_config hosts for one of them. Host names
throughout this document are the placeholders the tests use, standing in for the
real fleet. They are chosen so the derivation below actually reproduces, which the
first draft's names did not. The transcript below was printed by
`FleetOutput.numbered` from the fixture fleet with the old join still in place,
rather than typed out here, which is why it shows two rows: against the fix the
same query returns one:

```
$ hangar ssh wers
hangar: 2 hosts match "wers". Which one?
  1  workers.example             workers.example
  2  webstore.example  webstore  webstore.example
```

`wers` is not a subsequence of `webstore.example`, nor of `webstore`. The
question was where the second row could possibly have come from.

Row 1's middle column is blank because it is meant to be. That column is product
and env, and `workers` is a lead no sibling shares, so it never becomes a product
tag at all. The blank is the tell: row 1 is the host `wers` genuinely names, and
row 2 is the one that should not be there.

## What was actually true

`SearchEntry.metadata` joined four fields into one haystack. For an apex name
`SSHConfigImport` takes both `product` and `role` from the same first label, so
two of the four held the same string and the value appeared twice:

```
metadata "webstore webstore"
```

A subsequence match could start in one copy and finish in the next, taking `w`,
`e` and `r` from the first and `s` from the second:

```
[w][e]bsto[r]e web[s]tore
```

That is worse than a stray result. Duplication does not change what short queries
match, so `wer` matched before and matches now. It only lets *longer* queries
match what they otherwise could not, which defeats the one thing a person is
doing when they keep typing. On this fleet `wer` gave three hosts, `wers` gave
two, and `werse` still gave two.

| query | matches alias | matches `webstore` | matches `webstore webstore` |
|---|---|---|---|
| `wer`   | yes | yes | yes |
| `wers`  | no  | no  | **yes** |
| `werse` | no  | no  | **yes** |

Two conditions, and both are ordinary. `leadComponent` returns the registrable
label for a name of three labels or more and the first component otherwise, so
only an **apex** name has a lead that is also its own first label, which is what
`role` returns. And `derive` promotes a lead to a `product` tag only when more
than one host shares it, so the collision needs a **sibling**: `webstore.example`
alone gets no product at all, while `webstore.example` next to
`www.webstore.example` gets `product` and `role` both equal to `webstore`.

Both rows quoted in the report carried a populated group column, and that column
is only populated when a sibling shares the lead, so both of those hosts had one.
The fixture fleet deliberately mixes the two cases rather than making every host
collide: `workers` and `tower` have no sibling and so no product, which is what
shows that the fix moves only the host whose fields actually repeat.

That pairing is why the first draft of this document did not reproduce.
`webstore.example.com` has three labels, so its lead is `example` and its role is
`webstore`, and the haystack is `"example webstore"`, which never doubled.
`SSHConfigImportTests.testAnImportedCollisionDoesNotDoubleTheSearchHaystack` now
loads a config through the real importer and asserts the collision, so the
premise is pinned rather than narrated.

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
exactly as it is, and only the repeated value collapses. `wer` still gives three,
`wers` and `werse` now give one.

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
the imported fleet and asserts the counts. Against the old join it reports `wer`
four, `wers` two, `werse` two, the shape the report quoted; against the fix it
reports four, one, one. Its tags are the ones the importer really derives for
those names, sibling included, rather than a set hand-written to suit. The `DuplicateMetadataSearchTests` cases pin the haystack itself,
including the EC2 collision the issue used to show this is not an import problem.

## Reach

`Fuzzy.swift` reaches both front ends through `FleetIndex`, so the panel
(`Panel.swift:363`) and `hangar` (`main.swift:230`) behaved identically before
and behave identically after. That is why this got its own change rather than
riding along in the command line stack, which never touched this file.
