# 0028: a fleet with no AWS

## How this came about

The question 0025 asked was "if someone downloads this for their fleet, does it
work?" The first person to answer it with a fleet that has no AWS in it at all
filed issue #1. Seven hosts, every one from `~/.ssh/config`, EC2 switched off,
and the setup screen red:

> Preflight.profilesCheck takes AWSConfigFiles and an optional profile name. It
> is never handed the source settings, so it has no way to know EC2 is off, and
> with no profiles in ~/.aws/* it returns level: .problem unconditionally.

> The state field. state is an EC2 concept, and hosts from ssh_config carry
> "unknown". Anything treating "not running" as a warning marks every host on a
> fleet like mine. The styling meant to make the odd one out visible marks all
> of them.

He held the `state` half out of 0027 on purpose, so that whatever was decided
for the setup screen would be decided once and applied everywhere. This intent
is that decision.

## What was actually true

Hangar was an EC2 tool first, and `dc3b577` added three more sources without
revisiting what the EC2 parts assume. The assumption is not in three places. It
is in eleven, and the visible three are the mild ones.

**Hosts with no state are drawn as terminated.** `Brand.Color.state(for:)` falls
through to the terminated colour for any state it does not recognise, and the EC2
query never fetches terminated instances. So the only hosts that have ever worn
that red are hosts from a source with no state. The README promises that red is
reserved for instance state. On this fleet, red means "no AWS".

**They are not drawn at all in the cluster ring.** `ClusterView` batches host
particles by a fixed list of four EC2 states. An `"unknown"` host matches none
and is skipped. The circle says seven and the halo shows nothing, which is the
one thing this codebase says it never does: skip a host silently.

**The login probe never runs for them.** `SSHLogin.probeCandidates` requires
`state == "running"`. The once-per-machine login learning from 0026 is
unreachable from a fleet that has no EC2 in it.

**Yesterday's credential error never clears.** `FleetStore.refresh` skips the
AWS branch when AWS is off and never resets `credentialAdvice`, so a token that
expired before the user turned EC2 off stays on the setup screen indefinitely.

**The SSM toggle says on when SSM can never run.** SSM is attempted only after
EC2 is attempted and denied. With EC2 off, the checkbox reads on and the refresh
will never do it.

And the reason the obvious fix does not work: `"unknown"` is written by three
sources meaning three different things. For an ssh_config host it means "this
source has no concept of state". For a CSV row it means "the column was
missing". For an SSM host it means "PingStatus was not Online", which is a fact
SSM asserted and a host worth dimming. A renderer that skips the string would
silence a real signal. The sentinel is standing in for absence, and then being
treated as a value: mistake 23, in a different field.

## What was decided

**1. An absent state is not a state.** `Instance.state` becomes optional. Nil
means the source does not describe state. ssh_config hosts get nil. CSV rows get
the column's value if present, otherwise nil. EC2 and SSM are unchanged, so
SSM's `"unknown"` stays a real value that correctly dims.

**2. One answer to "is there a state worth mentioning".** `Instance.stateNote`
is nil when running and nil when there is no state; otherwise the state in
words. Every renderer makes that one call: the menubar row, the panel row, the
CLI listing, the cluster, the dashboard, and the login probe. None of them
compares strings.

**3. One answer to "is AWS part of this setup".** `SourceSettings.usesAWS`,
alongside `wants(_:)` and `attempts(_:)`. `FleetStore` already evaluates the
condition inline; it calls the property. `SetupWindow.isEnabled(_:)` moves down
to become `wants`. `attempts` is what refresh will actually do, and it is what
the SSM checkbox's detail reads.

**4. The AWS checks are told the source settings**, and the severity follows
one rule. AWS not wanted: a single informational row at `.ok` that says AWS is
off by choice and how to add it. Never absent, because a row that vanishes when
a toggle flips is a row nobody can find. AWS wanted and failed, with hosts from
elsewhere: `.warning`, which `hasHostsAnyway` already does. AWS wanted and
failed with nothing else: `.problem`, loud, with the advice for the profile that
was tried. A user with broken EC2 credentials is untouched by this.

**5. Red stays reserved.** `Brand.Color.state(for:)` takes the optional and
returns a neutral colour for nil. The cluster ring draws stateless hosts. The
hub stops saying "EC2" and says where the fleet came from, using the wording
`Preflight.sourcesCheck` already builds, so the picture and the check cannot
disagree.

**6. The CLI contract moves, and says so.** The TSV `state` column becomes empty
for stateless hosts, where 0.7.0 printed `unknown`. `-f state=unknown` stops
matching them. The JSON `state` key is always present, `""` when absent. This
ships as 0.8.0 with the move named in the notes, the way 0.7.0 named `--json`.
It is the second contract move in two releases; it is deliberate, and it removes
an annotation that was always wrong.

## Not decided here

SSM could say "connection lost" or "inactive" rather than "unknown". It is a
better word for a fact SSM did state, and it is out of scope: it changes a
value people may be filtering on, and it is not what issue #1 is about.

## The question to carry forward

Every EC2 concept in the model (`state`, `type`, `zone`, `asg`, `launchTime`)
is a candidate for the same treatment. When a fourth source arrives, the first
question is: which of these does it have no opinion about, and does every
renderer already know how to be told "no opinion"?
