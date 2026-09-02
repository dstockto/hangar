# 0008: a tag that reaches ssh as an option, and a tag that becomes a pattern

## How this came about

A security review was run over the published tree, the day after v0.0.1 shipped.
The question put to it was narrow: *trace every path where an EC2 tag value
reaches a dangerous sink, and prove each one passes a sanitizer.*

Two paths did not.

**Does an argument vector actually protect us?** The answer was no, and this is
the one that matters. `FleetStore.testConnection` built
`ssh <options> -l <user> <host> "true"`. Because a trailing argument follows the
host, `ssh` parses a host beginning with `-o` as an option. Reproduced:

```
ssh -o BatchMode=yes -l ec2-user "-oProxyCommand=touch /tmp/pwned" true
→ rc 255, and /tmp/pwned exists
```

`ProxyCommand` runs under `/bin/sh`, so a tag value is arbitrary code execution
as the user. It fires when someone Command-clicks a host and presses **Test**, and
**Detect Login** fires it thirteen times in parallel. `SECURITY.md` claimed
argument vectors covered this. They do not. Only `--` does.

**Is the `Host` line a value or a pattern?** A pattern, and it was being built by
raw interpolation while every *value* on the lines below it went through
`option()`. `isEmittable` rejects newlines, so no second directive could be
injected, but `*` passed. A tag of `hostname = *` produced:

```
Host payments-prod-web payments-prod-web-i-0abcdef0 *
  HostName *
```

`ssh -G` accepts that, so `sync()` installed it and reported success. Hangar's
Include sits at line 1 of `~/.ssh/config` and ssh_config is first-match-wins, so
every host the user had, their own bastions included, resolved to `HostName *`
and inherited Hangar's `User`, `IdentityFile`, `UserKnownHostsFile` and
`StrictHostKeyChecking`. Silently. This is the exact outcome
`.claude/skills/ssh-config-safety/SKILL.md` was written to prevent, arriving
through the one line in the file that skill did not think to mention.

A wildcard DNS record in a `dns` tag does the same thing by accident.

## Why the existing guards missed both

The sanitizers were right and were applied in the wrong places. `isEmittable`
answers "can this be one ssh_config argument", which is the correct question for
a value and the wrong one for a pattern. And nothing had asked what `ssh` does
with a host that looks like a flag, because "we pass an argument vector" had been
accepted as sufficient without being tested.

The eval that was supposed to catch unsanitized writes grepped for indented
directives, `lines.append("  [A-Z]`, so the single unindented raw write in the
file was invisible to it. An eval that cannot see the thing it guards is worse
than no eval, because it reads as coverage.

## What was decided

- `--` before any host that is followed by another argument, and the argv builder
  moves to `SSHProbe` in the core so it is testable rather than buried in a view.
- `isSafeAlias` for names on a `Host` line: letters, digits, dot, hyphen,
  underscore, no leading hyphen. Stricter than `isEmittable` on purpose, and
  applied twice, once where aliases are collected and again where the line is
  written, because that line is the one that can hijack everything.
- A host whose tag fails `isSafeAlias` still gets its entry under its generated
  alias. It loses only the tag-derived alias, so the fix costs reachability of a
  name, not of a host.
- The eval is rewritten to assert the invariant, that the `Host` line is built
  from an `isSafeAlias`-filtered list, rather than to pattern-match for danger.

## Also taken while here

Four advisory findings that were cheap and in the same files:

- `replaceItemAt` preserves the *destination's* mode, so an ssh include that
  already existed at 0644 stayed 0644 after every sync.
- `.atomic` writes create their temporary file at the umask, so first creation of
  the config, the fleet cache and the update stamp had a 0644 window.
  `createDirectory(attributes:)` does not tighten an existing directory either,
  so a hand-made `mkdir ~/.hangar` left that window reachable. Both now go
  through `PrivateFile`.
- `spctl` was run on the mounted image but not on the staged copy, while
  `REVIEW.md` and `SECURITY.md` said both gates ran on both. The code moved to
  match the claim.
- An `extra_options` keyword was only checked with `isEmittable`, so a keyword
  containing a space wrote two ssh tokens. Not reachable from a tag, but free to
  fix.

## Left alone deliberately

The review noted `hangar-probe` force-unwraps `utf8String` on AWS-derived
strings. It is a development target and `scripts/bundle.sh` does not copy it into
the bundle, so it does not ship. Recorded rather than fixed.

## Proof

Both reproductions were re-run against the fixed code, compiled from the real
`HangarCore` sources:

```
probe rc=255, pwned created: false
Host payments-prod-web payments-prod-web-i-0h
Host shop-prod-db shop-prod-db-i-0g db-1.prod.example.com
ssh -F <generated> -G bastion.corp.example → hostname bastion.corp.example
mode: -rw-------
```

`InjectionTests` covers all of it, 13 cases. 143 tests green.

## Consequence for the release

v0.0.1 is published and contains both. The argv path needs a user to click Test
or Detect Login on a hostile host, and the pattern path needs a `*` in a tag, so
neither is remote-triggerable, but both are real. This wants a 0.0.2.
