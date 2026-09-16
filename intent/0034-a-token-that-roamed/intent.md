# 0034: a token that roamed the whole name

## How this came about

Three terms typed at a fleet of a few hundred EC2 hosts, naming one host between
them, and a menu came back anyway. Names throughout this document are the
placeholders the tests use, in the shape the real fleet is tagged: a hostname of
`role.env.product.example.com`, an alias of `product-env-role`, and an
autoscaling group whose members carry an instance id in front of the hostname.
They are chosen so the derivation below reproduces. `torque` holds the `q`, and
no `a` follows it in either the alias or the tags, which is the condition.

```
hangar ssh payments qa torque
```

Five hosts on the fixture fleet, one of them `payments-qa-torque` and the other
four in prod, uat and dev. A person reading those five names can see that only
one of them is in qa.

The first guess was that `qa` was matching across two tag fields, which is the
question `0030` left open, and that scoring each field separately would answer
it. That was wrong, and worth writing down because it was wrong in an
instructive way.

## What was actually true

`qa` never touched the tag haystack. On `payments-prod-torque-1` the alias holds
a `q` in `torque` with no `a` after it, and the deduplicated tags read
`payments prod torque`, which fails for the same reason. The term qualified
those hosts through the **hostname**, one field, by taking its `q` from `torque`
and its `a` from a label further along:

```
i-0000000000000f264.torque.prod.payments.example.com
                    ^^^^^^      ^^^^^^^^
                       q         q     <- what `qa` alone matched
```

So per-field scoring could not have helped. Splitting `metadata` four ways
changes nothing about a token roaming inside a field that was never joined from
anything, and the alias and the hostname are already scored as fields of their
own. The condition is not "two fields hold the same string", as in `0029`, nor
"one token spans two fields", as in `0030`'s open question. It is simply that
subsequence over a whole name is too generous once names carry six labels, and
this fleet's do.

Two things made it hard to see, and both are the same defect.

**The highlight could not show it.** `Fuzzy.ranges` merged every term's ranges
together, and `qa`'s two characters both landed inside ranges another term had
already painted: the `q` under `torque`, the `a` under `payments`. A term that
matched invisibly and a term that matched nothing looked identical on screen. The
panel said `torque` and `payments` matched and said nothing about `qa`, which is
exactly what a person would read as "so why is this row here".

**Nothing narrowed.** `payments torque` gives five, and so does
`payments torque q`, because a bare `q` really is inside `torque` on all five.
Before this change `payments torque qa` also gave five. That is `0030`'s failure
again, one level out: the characters that should have started discriminating
were the ones free to roam.

## Decided

A token has to be **anchored** to how the name is written. Three ways to be
anchored, and a token needs one of them:

- **Inside one label.** `wstore` in `webstore`, `torq` in `torque`. This is the
  ordinary case and stays fully fuzzy.
- **Typed straight through the separators.** `paymentsprod` for `payments prod`,
  contiguously. `0030` kept per-field scoring out partly because it would have
  dropped these, so whatever replaced it had to keep them.
- **Read off the label initials.** `ppw` finding `payments-prod-web`, which is
  the docblock's own example and the reason `Fuzzy.score` rewards boundary hits.

Everything else is roaming, and `qa` against `torque.prod.payments` is roaming.

Anchoring is a **gate, not a weight**. A field offers a score only for a token it
admits; what it scores is unchanged. The weights in `SearchEntry.score` were
already tuned and ranking among the hosts that still match is identical, so this
change can be read as "which hosts match" without also being a re-tuning.

The highlighter now answers the same question, through the same `admits`. A term
that qualifies a host paints something a reader can point at, and a term that
paints nothing did not qualify it. See mistake 18: when a second thing answers a
question the first already answers, it has to call the first one. A match inside
one label is also confined to that label, so `tore` underlines `tore` in
`torque` rather than scattering to the end of the domain.

## What this drops, deliberately

Two assertions changed, and no others across 725 tests.

`pdw` no longer matches `payments prod prod-1 web`. That is `0030`'s open
question, closed the other way: one letter from each of three fields, naming none
of them. `ppw` survives, because every letter is a label initial. The trade is
worth taking on a fleet whose aliases carry four meaningful labels and whose
hostnames carry six, which is precisely the shape that makes roaming useless.

`werse` no longer matches `workers.example`, where `0030` recorded one. It
reached its last `e` by leaving `workers` and landing in `example`, the domain
all four fixture hosts share. Nothing on that fleet is named `werse`, so zero is
the honest count, and the property the test exists for is intact: `wer` gives
four, `wers` gives one, `werse` gives none.

## What proves it

`RoamingTokenSearchTests` builds the fleet through `FleetIndex` and asserts
`payments qa torque` returns exactly `payments-qa-torque`, where every term
matched all five before. It also pins the instance-id label, which is 19 more
characters of hex for a token to roam through: a token may look inside it and
find the host, and `f264torque` still matches because straight through a
separator is the same rule that keeps `paymentsprod`, but `f2torque` does not,
because skipping characters on the way out of the id is roaming.

`AnchoredTokenTests` pins each of the three routes separately, including
`paymentsprod`, which is the case `0030` named as a reason not to go per-field.

`HighlightAgreesWithScoreTests` asserts the marks themselves rather than a count,
so a term that paints nothing is visible as nothing in the test too.

## Reach

`Fuzzy.swift` reaches both front ends through `FleetIndex`, so the panel and
`hangar` narrow identically, as they did before. `Fuzzy.Haystack` is built once
per entry per refresh alongside the bytes it already built, so the per-keystroke
path still splits only the query. `Fuzzy.score` itself is untouched: the label
rule is policy on top of the primitive, which is why `FuzzyTests` needed no
changes.
