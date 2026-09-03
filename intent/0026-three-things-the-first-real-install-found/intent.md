# 0026: three things the first real install found

## How this came about

0.2.0 was published, then installed from scratch on a machine with a real fleet
and a real 1Password vault. The flow worked. Watching it work found three things
that reading the diff had not.

## 1. Auto-adopt never fired for anyone who already had Hangar

Adopting the agent's key ran inside `runChecks()`, and the setup window opens on
launch only when onboarding has not completed. So the fresh install worked and
the upgrade did not: everyone coming from 0.1.6 with 1Password installed kept the
old behaviour until they happened to open **Setup Check** from the menu.

A feature nobody can find is not a feature. It moves to `FleetStore`, runs once
per launch after the first refresh, and the setup screen calls the same method.
Once per launch, not per refresh: it starts a process, and a fleet refreshing
every half hour is no reason to keep poking at somebody's vault.

## 2. Reset left the keys behind

`HangarReset.everything` removed the config that named `~/.hangar/keys/*.pub` and
left the files. Uninstall was fine, because it removes all of `~/.hangar`. Reset
was not, and a reset that leaves state behind is not a reset. The key directory
and the new login marker join the list.

## 3. Hangar guessed the login, and its guess outranked the user's own config

> want this to work for more than EC2 Describe Instance Permission + Current User
> + Key in home dir

The third of those, finally. `HangarConfig.standard()` set `user: NSUserName()`
and the writer emitted it for every host, so an SRE whose images use `ec2-user`
got their macOS account name on all 223 aliases.

Worse than a wrong default: Hangar's `Include` sits at the top of
`~/.ssh/config`, and ssh_config is first-value-wins, so that guess **beat a
`Host * / User ec2-user` the user had written themselves**. Same family as the
`IdentitiesOnly` bug in [0023](../0023-a-key-you-never-have-to-name/intent.md):
Hangar asserting something it did not know, in a file where asserting wins.

Two options were put up. Omit `User` entirely and let ssh decide, or probe once
and learn it.

> probe once and learn it for 3

**Decided: probe.** The concern with probing is real and it shaped the design
rather than blocking it. An unprompted outbound authentication attempt, repeated
or fanned across a fleet, is how someone's laptop ends up banned by their own
fail2ban. So every bound is deliberate:

- **One host**, not the fleet. Running, not Windows, and not an imported host,
  whose login the user's own config already carries.
- **Six attempts at most**, not the full twelve-name candidate list.
- **The platform first.** `platformDetails` already came back with the fleet and
  separates Ubuntu, Red Hat, SUSE and Debian. A free hint that usually turns six
  attempts into one. It is a billing field, so it lumps Amazon Linux and stock
  Ubuntu under `Linux/UNIX`, and there it says nothing rather than guessing.
- **Once per machine**, behind `~/.hangar/.login-probed`, written *before* the
  attempt so a probe that crashes does not come back on the next launch.
- **The default is still nothing.** `standard()` no longer ships a login, so
  until the probe learns one, ssh does what it already does and the user's own
  config wins.
