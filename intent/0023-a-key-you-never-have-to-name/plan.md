# 0023 plan

| Order | File | Change |
|---|---|---|
| 1 | `HangarCore/ProcessRunner.swift` | new: run with a deadline, terminate, then kill |
| 2 | `HangarCore/Credentials.swift` | `runCredentialProcess` uses it, one implementation |
| 3 | `HangarCore/KeySource.swift` | new: agents, key files, `ssh-add -L` parsing, materialize |
| 4 | `HangarCore/HangarConfig.swift` | `identity_agent`, `identities_only` on settings and overrides |
| 5 | `HangarCore/SSHConfigWriter.swift` | emit the agent lines; `IdentitiesOnly` becomes explicit |
| 6 | `HangarCore/Preflight.swift` | `keyCheck` |
| 7 | `Hangar/SetupWindow.swift` | the Hosts and keys card, key half |
| 8 | `Tests/KeySourceTests.swift` | parsing, slugging, detection shape |
| 9 | `Tests/SSHConfigWriterTests.swift` | the three emitted lines, and the suppression case |
| 10 | `README.md`, `site/index.html` | what it does and that no private key is read |

Proven by: the new tests, plus a real 1Password agent on the developer's machine
listed through `hangar-probe --keys`.
