<!-- Keep this short. The diff shows the what; say the why. -->

## What this changes, and why

## Checks

- [ ] `make test` green
- [ ] `evals/check.sh` green
- [ ] `make testbed` green, if this touches a host source, the merge, or the writer
- [ ] The passes in [REVIEW.md](../REVIEW.md) that apply to what I touched
- [ ] An `intent/<n>-<slug>/intent.md`, if a user could notice this or it touches
      credentials, `ssh_config`, or the updater

## If this adds an eval

Plant the mistake it is meant to catch and confirm the case goes red before you
trust it. A guard shaped `! grep ...` passes when the grep itself is broken.

## If this changes output anyone might be parsing

Say which shapes moved and which did not. `--json`, `--tsv`, `-a` and the default
listing are separate contracts, and something is piping each of them.

## Anything you deliberately left undone

Say so here rather than leaving it to be found. A known gap with a reason is a
review comment; a silent one is a bug.
