# 0012: uninstall from the menu

## How this came about

> can you add uninstall in the menu bar ?

0011 gave Hangar a reset, and stated in `SECURITY.md` that "deleting the app and
that directory leaves nothing behind". True, and it puts the work on the user:
two Finder trips, one of them into a dot-directory they have no reason to know
about, plus a stale `Include` line in a file the reset deliberately would not
touch.

## What a reset would not do, and an uninstall must

A reset keeps Hangar usable afterwards, so three things were correctly out of
scope for it and are all in scope here.

- **The directory, not the files in it.** Reset removes named files inside
  `~/.hangar`. An uninstall removes `~/.hangar`. An empty support directory left
  behind is exactly what made a delete and reinstall look like it had not taken,
  which is the bug 0011 fixed.
- **The `Include` line.** Reset leaves it because it is the user's file and the
  line is harmless pointing at nothing. After an uninstall, "harmless" is no
  longer the point: nothing of Hangar's should remain. So the line goes, only
  lines Hangar itself would have written are matched, and the file is copied to
  `config.hangar-backup` first and rewritten at 0600.
- **The login item and the bundle.** Unregistering `SMAppService` needs the
  bundle still in place, so it happens before anything is removed.

## Removing the running app

The app cannot delete its own bundle while running, so a detached helper waits
for the process to exit, the same shape as the update swap helper and for the
same reason.

Two decisions inside it:

- **`mv` to `~/.Trash`, not `rm -rf`.** Mistake 6 in `CLAUDE.md` was deleting
  before the replacement succeeded. The general form of that lesson is that an
  irreversible step should be a move. The Trash also makes the whole operation
  recoverable, which is worth more than tidiness.
- **Not Finder.** `tell application "Finder" to delete` is the idiomatic way to
  trash a file and would have given the user Put Back, but controlling Finder
  needs Automation consent and the prompt would arrive after Hangar has quit,
  attributed to a process that no longer exists. A plain `mv` needs no consent.

The helper is staged and written *before* anything is removed, so a helper that
cannot be written leaves the install whole rather than half gone. Likewise, a
file that cannot be removed stops the uninstall and says so, with the app still
installed, rather than continuing and trashing the bundle over the top.

## What it does not touch

`~/.aws` in any form, `known_hosts`, and every line of `~/.ssh/config` that
Hangar did not write. Stated as tests, so the blast radius cannot widen quietly.
