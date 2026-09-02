# 0016 plan

| Order | File | Change |
|---|---|---|
| 1 | `HangarCore/Log.swift` | new: `Log`, `Category`, level, line rendering, the file actor, rotation |
| 2 | `HangarCore/Redact.swift` | new: `Redact.host`, `Redact.instance` |
| 3 | `HangarCore/HangarConfig.swift` | `logPath`, under `~/.hangar/logs` |
| 4 | `HangarCore/{Credentials,SSHConfigWriter}.swift` | call sites in the table |
| 5 | `Hangar/{HangarApp,FleetStore,Updates}.swift` | call sites in the table |
| 6 | `Hangar/MenuBarController.swift` | Reveal Log in Finder, and the path row |
| 7 | `HangarCore/HangarReset.swift`, `HangarUninstall.swift` | the log directory goes with everything else |
| 8 | `Tests/LogTests.swift`, `Tests/RedactTests.swift` | the five cases in the spec |
| 9 | `README.md`, `SECURITY.md` | what is written, where, and what is redacted |

Proven by: the new tests, and reading `~/.hangar/logs/hangar.log` after driving
the built app through a refresh and a failed credential resolution.
