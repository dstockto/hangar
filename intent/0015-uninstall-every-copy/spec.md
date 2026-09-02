# 0015 spec: uninstall every copy

## Discovery

The candidate set is the running bundle plus
`NSWorkspace.shared.urlsForApplications(withBundleIdentifier:)` for Hangar's own
identifier. Both are needed: Launch Services can miss a copy that has never been
launched, and it can list a copy that is no longer there.

`InstalledCopies.toRemove(running:found:isRemovable:)` in the core decides the
list. It standardizes each path, drops duplicates case-insensitively (Launch
Services reports the same bundle by more than one route), keeps the running copy
first, and keeps only paths `isRemovable` accepts. The app layer's predicate is
"the parent directory is writable and the volume is not read-only", so a Hangar
launched from a mounted DMG is reported rather than attempted.

`InstalledCopies.leftInPlace(...)` returns the rest, for the dialog.

**Refined during build.** Launch Services also reports copies that are not
installs. On the development machine it returned `dist/Hangar.app`, the build
output in the source tree, because it had been launched once. Trashing someone's
build product is not what uninstall means, so a found copy counts only when it
sits under an install root, `/Applications` or `~/Applications`. The copy the
user actually uninstalled from is always removed, wherever it lives, because
they pressed the button in that one. Everything else found is named in the
dialog as left alone.

## The dialog

Unchanged in shape, with the list added under the paragraph:

```
Uninstall Hangar?

Removes ~/.hangar, the ssh aliases Hangar generated, and the Include line
Hangar added to ~/.ssh/config. Hangar stops opening at login, then quits and
moves itself to the Trash, where you can put it back. Your AWS credentials and
the rest of your ~/.ssh/config are not touched.

These copies will be moved to the Trash:
/Applications/Hangar.app
~/Applications/Hangar.app

Found but left alone, because it is not an installed copy:
~/code/hangar/dist/Hangar.app

[Uninstall Hangar]  [Cancel]
```

When a copy cannot be moved, a second line names it and says it will be left in
place. The buttons do not change: the user is still approving one operation.

## Order of operations

1. Stage the removal helper. A helper that cannot be written aborts before
   anything is removed.
2. Terminate every other running instance, so nothing rewrites `~/.hangar` after
   step 4. Each gets `terminate()` and up to three seconds to go; one that
   refuses is not fatal, because its bundle is about to move anyway.
3. Unregister the login item, which needs a bundle still in place.
4. Remove `~/.hangar`, the generated aliases, and the `Include` line. A failure
   here stops the uninstall with the app still installed.
5. Run the helper and quit.

## The helper

One `mv` per bundle after the app has exited, `~/.Trash` created if it is
missing, a timestamped name on collision, and one notification if any bundle
could not be moved, naming how many. Never `rm`: the Trash is what makes an
uninstall recoverable.

## Tests

In the core, because that is where the decision lives:

- The running copy is always first in the list.
- Duplicates from Launch Services collapse, including case differences.
- A path `isRemovable` rejects appears in `leftInPlace`, not in `toRemove`.
- A build outside the install roots is left in place, and the running copy is
  removed even when it is itself outside them.
- Nothing found is dropped: the two lists partition the input.
- `describe` abbreviates the home directory and nothing else.

The helper script keeps its existing shape, exercised against a sandboxed `HOME`
with two fake bundles, one of them colliding with a name already in the Trash.
