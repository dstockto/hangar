# 0005: an updater that was described but not connected

## How this came about

Two instructions, a few minutes apart:

> add auto updater, check once per day, default on

> check updates should pull from github and offer to inplace update the app

and then, when the manual path was made to offer the install:

> same with daily check

The second instruction is the interesting one, because the answer was that the
code to do it already existed and had never run.

## What was found

`Updates.stage` downloaded a DMG, mounted it, verified notarization and a pinned
Developer ID team, staged the bundle beside a swap script, and returned a closure
that would install it. Complete, careful, and called by nothing. Meanwhile
`README.md`, `SECURITY.md` and `RELEASING.md` all described how the in-place
updater verified downloads before replacing anything.

The documentation described a code path that could not execute. That is worse
than a missing feature: a reader has no way to tell the difference, and the claim
was load-bearing for trust.

## The design questions

**How often is "daily"?** Not once per launch. A laptop that sleeps and wakes all
day would check twenty times. The last-check timestamp lives on disk, so the
clock survives a restart, and the timer ticks hourly and usually decides it is not
due yet. That is what makes the schedule survive the way laptops are actually
used.

**How much may an unprompted check do?** Not spend bandwidth without asking. A
check the user asked for goes straight to download, verify, stage, confirm. The
daily one asks first, with the release notes as a third option. Neither replaces
the running app without an explicit confirmation.

**What changes in the promise?** The README said Hangar makes no network request
the user did not ask for. Turning the check on by default makes that false, so
the sentence changed with the default rather than after someone noticed.

## What was kept exactly as it was

The verification chain, because it was already right: `spctl`, the pinned
`certificate leaf[subject.OU]` requirement, `ditto` for the copy, and a detached
helper that waits for exit, moves the installed app aside, swaps, relaunches, and
restores on failure. It only needed calling.

## Proof

`UpdateScheduleTests`: off at zero hours, due when it has never run, not due
inside the window, due outside it, and the stamp surviving a restart. The install
path itself was verified by hand against an ad-hoc re-signed bundle, which both
gates rejected.

`ConfigCodingTests.testDefaults` had asserted the old default and was updated
deliberately, which is the correct outcome: the test was right about the old
behaviour and the behaviour changed on purpose.
