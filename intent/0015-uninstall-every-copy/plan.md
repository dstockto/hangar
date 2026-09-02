# 0015 plan

| Order | File | Change |
|---|---|---|
| 1 | `HangarCore/InstalledCopies.swift` | new: `toRemove`, `unremovable`, `describe` |
| 2 | `Hangar/Uninstaller.swift` | take `[URL]`; helper loops, creates `~/.Trash`, reports how many failed |
| 3 | `Hangar/HangarApp.swift` | discover copies, list them in the dialog, terminate other instances, then the existing order |
| 4 | `Tests/InstalledCopiesTests.swift` | the four cases in the spec |
| 5 | `README.md`, `SECURITY.md` | "moves the app to the Trash" becomes "moves every installed copy" |

Proven by: the new tests, plus the helper script exercised against a sandboxed
`HOME` with two bundles and a name collision.
