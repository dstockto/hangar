# 0027 spec: what `hangar` does after this

Everything not stated here is unchanged. The command still reads
`~/.hangar/cache` and nothing else, makes no AWS call, spends no credential, and
writes nothing.

## Grammar

```
hangar [verb] [query...] [options]
```

The **first plain word** on the line is a verb when it is exactly `ssh`, `tags`
or `values`. Anything else is the start of the query, so `hangar web prod` is
unchanged, and so is `hangar web tags`, whose second word is already part of a
search. Options may come first: `hangar --json tags` is the `tags` command.

Two escapes reach a host whose name is a verb:

```sh
hangar -s ssh      # -s always means query
hangar -- ssh      # nothing after -- is a verb or an option
```

With no verb, the command lists, which is what it does today.

## Verbs

| Verb | Does |
|---|---|
| *(none)* | Prints matching hosts. Today's behaviour. |
| `ssh <query>` | Connects to the one matching host. |
| `tags` | Prints the tag keys this fleet uses, with coverage. |
| `values <key>` | Prints the distinct values of one tag key, with counts. |

### `hangar ssh <query>`

- **One match:** replaces this process with `ssh`, so the session owns the
  terminal and ssh's own exit status is the command's.
- **Several matches at a terminal:** prints them numbered, reads a number on
  stdin, connects to that one. An empty line or EOF cancels with exit 3.
- **Several matches not at a terminal:** prints them on stderr and exits 3
  without connecting. A script or an agent has to be specific, or say `--first`.
- **No match:** exit 1, as everywhere else.
- `--first` (`-1`) takes the top-ranked match without asking, which is what
  `| head -1` meant and says so.
- `--dry-run` prints the argument vector it would have run and exits 0.

The vector comes from `SSHCommand.arguments`, the same decisions
`SSHCommand.line` makes for the panel, so the menubar and the shell cannot
disagree about which user or key a host gets. `--` separates the options from
the host, per mistake 9.

### `hangar tags`

Columns: key, how many hosts carry it, how many distinct values, and up to three
sample values, most-carried first. `-a` gives the key names alone, `--tsv` and
`--json` the same data for a machine.

Discovered from the fleet's own tags, **before** the mapping resolves them,
which is the same thing `FleetCache.tagCatalog` holds.

This spec said the opposite for a while and the reversal is worth keeping,
because the reasoning that produced it was wrong in an instructive way. The
first draft read the *normalized* fleet, on the argument that a list you cannot
then select from is worse than no list, so `tags` should agree with `-f`.

Two things were wrong with that. `normalize` writes the canonical key and keeps
the original, so discovering from the normalized fleet listed every grouping key
twice: a fleet tagged `Environment` saw both `Environment` and `env`, identical
counts, identical samples. And it bought no agreement anyway, because `-f`
resolves nine names whatever the fleet happens to call them, so a fleet's own
`Role` tag is unreachable by that key either way.

Agreement was not available. Saying so was. The table marks the rows `-f` will
resolve past, and `values` still reads through `tagValue(for:)`, so the two
commands answer two different questions and each says which one it answered.

### `hangar values <key>`

Every distinct value of one key across the fleet, with a host count each,
most-used first. Accepts the friendly names `tagValue(for:)` accepts, so
`hangar values name` finds the `Name` tag, and `hangar values state` works
although `state` is not a tag at all. `-a` gives the values alone, one per line.

A key no host carries exits 1 and says to try `hangar tags`.

`values` reads through `tagValue(for:)`, so what it lists is what `-f` matches.
`tags` does not, and cannot: it lists the fleet's own key names, and `-f`
resolves nine of them whatever the fleet calls them. The table marks those rather
than claiming an agreement that does not exist.

## Filters

`-f` gains two things and loses none.

```
-f env=prod              exact, or wildcard, exactly as today
-f env=prod,staging      any of these
-f env!=prod             none of these
-f name!=*canary*        wildcards work on both sides of the negation
-f env=a\,b              a backslash escapes a comma in a value
```

Repeated `-f` still means AND, including twice on the same key, which the old
dictionary could not express because the second silently replaced the first.

`state` was always filterable through `tagValue(for:)` and was never documented.
It is now.

The dictionary form `FleetIndex.filtered(_:by:)` stays exactly as it is. Hotkey
filters in `~/.hangar/config.json` are unchanged and unaffected.

## Output

### At a terminal

When stdout is a terminal, the default listing gains, in this order:

- A group heading per product and environment, matching the order the menu uses,
  because `FleetIndex.entries` already sorts by it.
- A state column, and rows whose state is not `running` are dimmed **and** say
  their state in words. Colour never carries state alone.
- No trailing padding on the last column.

Colour is suppressed when `NO_COLOR` is set to anything, when `TERM` is `dumb`,
and whenever stdout is not a terminal.

### Not at a terminal

Byte for byte what 0.6.1 prints. `hangar | fzf | awk '{print $1}'` keeps working,
and so does every pipeline nobody told us about.

### `--json`

Still a single top-level array, so `hangar --json | jq -r '.[].hostname'` from
the README is unaffected. Each object gains:

| Field | From |
|---|---|
| `type` | `instance.type` |
| `vcpus` | `instance.vcpus`, a number, absent when unknown |
| `launch_time` | `instance.launchTime` |
| `asg` | `instance.asg` |
| `lifecycle` | `instance.lifecycle` |
| `private_dns` | `instance.privateDNS` |
| `tags` | the instance's own tags, as an object |

`vcpus` is a JSON number. Everything else stays a string, and `tags` is the only
nested value.

**`--json` always prints a valid document.** When nothing matches it prints `[]`
and exits 1. The exit code still says nothing matched; stdout is still
parseable. This is the one promise in this change that is currently false, so it
gets an eval.

## `--exec`

```
hangar [query] [-f ...] --exec <program> [arguments...]
```

`--exec` consumes the rest of the command line. The program is run once per
matched host, with these substitutions applied **per argument**, never through a
shell:

```
{alias} {hostname} {id} {product} {env} {env_name} {role}
{private_ip} {public_ip} {state} {type} {zone}
```

An unknown `{name}` is left alone rather than replaced with nothing, because
silently emptying part of somebody's command is worse than passing it through.

- The program is resolved on `PATH` and run with an argument vector. No shell
  parses any of it, so a tag value cannot become a second command. This is the
  reason `--exec` exists rather than a documented `$(hangar -a ...)` loop.
- `--parallel <n>` runs up to n at once, default 1. At 1 the child inherits this
  process's stdin, stdout and stderr, so an interactive program works. Above 1
  output is captured and printed per host under a heading, because interleaved
  output from eight hosts is not output.
- `--timeout <seconds>` bounds each invocation. Unset by default: unlike a
  credential helper, this is the user's own foreground command and may be a
  session they intend to sit in.
- **Confirmation.** Running against more than one host asks first, showing the
  count and the command. `-y` skips the question. When stdin is not a terminal
  there is nothing to ask, so `-y` is **required** for more than one host and its
  absence is a usage error. An agent has to say out loud that it meant to fan
  out.
- `--dry-run` prints every vector it would run, one per line, and exits 0.

## Exit codes

```
0   hosts were printed, or the work finished
1   nothing matched
2   no fleet cached yet
3   more than one host matched and none was chosen
4   a command run under --exec failed on at least one host
64  the command line itself was wrong
```

`3` and `4` are new. `0`, `1`, `2` and `64` keep their meanings.

## Warnings

The stale-cache and missing-`Include` warnings still go to stderr and still
leave a pipe alone. They are now said **once per process** rather than once per
call, which matters because `--exec` against thirty hosts used to mean thirty
identical lines. `--quiet` and `HANGAR_QUIET=1` suppress both.

## Security

- No tag value reaches a shell anywhere in this change. `--exec` substitutes into
  an argument vector; `ssh` gets a vector with `--` before the host.
- `--exec` runs a program the user named on their own command line, with the
  arguments they wrote. That is the same authority as typing it, and less than
  `$(hangar -a ...)` in a shell, which re-parses the aliases.
- Nothing new is written. Nothing new is read except the cache and
  `~/.hangar/config.json`, both already read.
- `--dry-run` output is for reading, so anything printed as a command line is
  quoted with `Shell.quoted`. It is never handed to a shell by Hangar.
