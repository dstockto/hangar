# 0015: uninstall means every copy

## How this came about

> on 0.0.5 I uninstalled but the app was still in applications folder, check if
> 0.0.6 has the same bug

It does, because it is the same code. What the machine actually showed:

| Path | State |
|---|---|
| `~/Applications/Hangar.app` | gone; this is the copy that was running, and the uninstall moved it |
| `/Applications/Hangar.app` | still there, 0.0.5, dragged from the DMG at 10:40 |

So the uninstall did exactly what it was written to do, and what it was written
to do is wrong. It moved `Bundle.main.bundleURL`, one bundle, the one it happened
to be running from. Two copies is not an exotic state: a DMG dragged to
Applications plus a build installed elsewhere is a Tuesday.

The consequences are worse than an unused file. The surviving copy still opens at
login, and the first time it launches it writes `~/.hangar` and the ssh aliases
back. An uninstall that gets undone by the copy it missed is not an uninstall.

## The decision

Remove every copy. Ask Launch Services for every bundle carrying Hangar's
identifier, add the running one, list them in the confirmation dialog so the
removal is approved with the list visible, quit any other running instance before
touching the files, and move them all to the Trash.

A copy that cannot be moved, which in practice means one running from a mounted
DMG, is named rather than attempted. Silence about a copy left behind is the
whole bug; it must not survive the fix.

## Out of scope

- Copies belonging to another user account. Hangar removes what this user can.
- Unregistering Launch Services entries. They are stale, harmless, and rebuilt
  by the system.
- Anything under `~/.aws`, and any line of `~/.ssh/config` Hangar did not write.
