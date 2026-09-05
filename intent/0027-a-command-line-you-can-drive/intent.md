# 0027: a command line you can drive

## How this came about

0.6.1 was installed by someone who does almost everything from a terminal and
has opened the panel maybe twice. The `hangar` command went in at 0.5.0 for
exactly that person. Their first report on it:

> The cli interface seems clunky to me. I know it's not "clunky" for you since
> dealing with output that it gives is easy but it's not the best interface for
> a human.

That is a fair description of what was built. `hangar` is a **printer**, not a
tool. It answers one question, "which hosts match this", in four formats, and
every action is left to the shell. The README's own examples are the evidence:

```sh
ssh "$(hangar -a -s 'web prod' | head -1)"
hangar | fzf | awk '{print $1}' | xargs ssh
```

Thirty characters of shell ceremony around a twelve-character intent. In the
panel that same intent is one hotkey, some typing, and Return. The command line
was designed for the pipe, and the human was handed the pipe's interface.

## The second reader

The same report asked for something the panel cannot do at all:

> I would like it to be something that I can use easily as a human but also
> something I could direct claude at like `open all my whatever servers in one
> herdr window split into a grid and then run <cmd> on all of them` and it could
> use hangar to help with figuring out what servers to go to.

So there are two readers now, and they want nearly the same things for different
reasons. Both need to find hosts without already knowing the tag vocabulary.
Both need a selection they can trust before acting on it. Both need an action
that is not "construct a shell string yourself".

An agent driving `hangar` today gets one of the three. It can list. It cannot
ask what tag keys exist, it cannot express "prod but not the canaries", and when
it does have twelve hosts it has to hand-roll the entire terminal integration,
because nothing here does anything but print.

## What was decided

Seven changes, in the order they depend on each other. Each is small enough to
disagree with on its own.

**1. The command line gets a testable shape.** `hangar-cli/main.swift` holds its
argument parsing and its four formatters in an executable target, where the
suite cannot reach them. That is the same rule that moved `SSHCommand` and
`UpdateSchedule` down: logic belongs in `HangarCore`. Nothing else here is safe
to build on top of an untested parser.

**2. Filters can say what people actually want.** `-f key=value` is exact or
wildcard, AND only, one value per key. The real questions are "prod or staging",
"anything except the canaries", "running only". `HostFilter` adds a comma list
and `!=`, and leaves the dictionary form the hotkeys use alone.

**3. `--json` carries the whole host.** `fields()` picks thirteen strings and
drops `type`, `vcpus`, `launch_time`, `asg`, and the instance's own tag map. So
"the m5.large ones" and "everything in the payments ASG" are unanswerable from
JSON while sitting in the cache the command just read. It also prints *nothing*
when nothing matched, so `jq` downstream fails on empty input rather than
reading an empty array. An empty result is an answer, not a parse error.

**4. The tag vocabulary is discoverable.** `-f` requires you to already know the
keys and the values. `TagCatalog` knows exactly which keys the fleet uses, how
many hosts carry each, and sample values, and it is already persisted in the
cache for the setup screen. None of it is reachable from a terminal.

**5. The human view stops being constrained by `awk`.** Every reader gets output
shaped for a pipe: no state, no grouping, 249 rows of padding. Branching on
`isatty(1)` costs nothing and breaks nothing, because a pipe keeps exactly the
bytes it gets today.

**6. `hangar ssh` connects.** The eighty percent case has no command. `head -1`
is load-bearing in the documentation, and it silently accepts the top-ranked
host with no signal that there were eleven others. One match connects, several
ask, and `--first` is there for the caller who really did mean the top one.

**7. `--exec` runs something per host, without a shell.** This is the herdr
request, and the answer is not to teach Hangar about multiplexers. iTerm2,
Terminal and Ghostty are already three integrations; herdr, tmux, kitty and
WezTerm would make the launcher a matrix. `--exec` is `xargs` with names instead
of positions, and because substitution happens per argument in an argument
vector, **no tag value ever reaches a shell**. `$(hangar -a ...)` cannot say
that.

## The one thing that gets worse

`hangar ssh` and `hangar tags` make the first argument a verb, and until now
every argument was a query. A host whose alias fuzzy-matches `ssh` is no longer
listed by `hangar ssh`.

Two options were put up. Spell the new commands as flags, `--ssh` and `--tags`,
which collides with nothing and reads badly for the one command people will type
most. Or take the collision and give it an escape.

**Decided: verbs, with two escapes,** because `hangar ssh web prod` is the
sentence people will actually type, and because the collision is smaller than it
looks: search is subsequence matching, so `hangar ssh` today ranks every alias
containing s, s and h in that order, which is not a result anybody wanted. The
escapes are `-s`, which the help already documents as "the same, spelled out",
and `--`, which is what it means everywhere else.

## Out of scope

Named deliberately, because each came up and each is a different change:

- **`hangar refresh`.** The staleness warning tells a terminal user to go open a
  menubar app. Fixing that needs a way to poke the running app, which does not
  exist yet, and inventing a URL scheme belongs in its own intent.
- **`hangar doctor`.** `Preflight` is in the core and most of it would work, but
  the terminal and login-item checks reach `NSWorkspace`. Splitting those is a
  bigger change than it looks.
- **An interactive picker.** `hangar ssh` prompts when a query is ambiguous, and
  that covers most of what a picker is for. A full filter-as-you-type reader
  means raw mode and a redraw loop in a target that currently prints and exits.
- **Shell completion.** Cheap and genuinely useful, and it is a maintained
  artifact per shell rather than a change to this program.
- **Refreshing anything, calling AWS, or writing anything.** The command still
  reads `~/.hangar/cache` and nothing else. That property is why it is fast
  enough to put behind a keystroke, and none of the above needs to spend it.
