# 0032: a hand edit the app wrote over

## How this came about

Issue 9. Someone set a default ssh login by hand, which is the thing this project
tells people to do. Their remote login is lowercase and their Mac account name is
not, so they added `"user"` to the `ssh` block in `~/.hangar/config.json` and then
chose Write Aliases Now. The generated `~/.ssh/config.d/hangar` came out with no
`User` line at all. It appeared only after Refresh Fleet.

The header Hangar itself writes at the top of that file says to do exactly what
they did:

```
# Change ssh user, key, or per-group options in ~/.hangar/config.json,
# then sync again from the Hangar menu.
```

So the file gave an instruction the command below it did not honour.

## What was actually true

`FleetStore.config` is an in-memory copy of a file whose whole design is that a
person edits it. `reloadConfig()` is what refreshes that copy, and it ran in five
places: at launch, at the top of `refresh()`, when hotkeys are registered, after a
reset, and after the app wrote the file itself. `syncSSHConfig` was not one of
them, so Write Aliases Now rendered from whatever was in memory and a hand edit
was invisible to it until something else happened to reload.

That is the reported bug, and it is the smaller half.

The reporter guessed at a second one without testing it, and was right. Fifteen
places did this shape:

```swift
var config = store.config     // a snapshot that may be minutes old
config.launchAtLogin = turningOn
try? HangarConfig.write(config)   // writes the whole struct back
store.reloadConfig()              // re-reads the file it just overwrote
```

`HangarConfig.write` serializes every field. So toggling one checkbox wrote a
stale copy of *all* of them over the file, discarding any hand edit made since
that copy was taken. The trailing `reloadConfig()` looks like a guard and is not:
it re-reads the file after the clobber, so it loads the damage back into memory
and the user's edit is gone from both. Write Aliases Now ignored a hand edit;
Open at Login silently deleted one.

Nine of those fifteen sites are in `FleetStore` itself (`saveOverride`,
`useProfile`, `useTerminal`, `useTagKey`, `setGroupingKeys`, `learnLoginIfUnset`,
both `adopt` overloads, `clearKeyPreference`), three in `MenuBarController` and
three in `SetupWindow`. Every one of them reads `config`, changes one field, and
writes the whole thing.

## What was decided

The issue proposes calling `reloadConfig` before the sync and before each write.
That fixes today's fifteen and does nothing about the sixteenth, which is the
shape of mistake 18 in CLAUDE.md: when a second thing answers a question the
first already answers, it has to call the first one. A rule that lives in fifteen
call sites is a rule that gets forgotten once.

So the read-modify-write becomes one operation, and it lives in `HangarCore`
where it can be tested. `FleetStore` is AppKit and `@MainActor`, and the offline
suite only imports `HangarCore`, so a fix written only in `FleetStore` is a
behaviour change with no test, which Pass 1 of REVIEW.md does not accept.

**`HangarConfig.update(at:_:)`** re-reads the file, applies the change to what is
actually on disk, and writes that back. The caller never holds the copy it is
changing, so there is no window to be stale in. `FleetStore.updateConfig` wraps
it, keeps the in-memory copy in step and rebuilds the search index when the ssh
shape changed, and all fifteen sites go through it.

**A malformed config refuses the write rather than replacing it.** If the user is
mid-edit and the JSON does not parse, the old behaviour would write the last good
in-memory copy over their work. `load()` already documents the opposite rule, that
a config which fails to parse is reported rather than silently replaced, so a typo
never costs the user their settings. `update` keeps that promise: it throws, the
file is left exactly as the user left it, and the caller reports it.

**`syncSSHConfig` reloads first**, which is the reported bug and is now one line,
because the sync renders from the config and the config may have changed.

The generated header stays as it is. It was never wrong about what should happen.
