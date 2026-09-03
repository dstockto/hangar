# 0024 plan

| Order | File | Change |
|---|---|---|
| 1 | `HangarCore/HostSource.swift` | new: provenance, `FleetMerge`, source settings |
| 2 | `HangarCore/Models.swift` | `source`, `preferredAlias`, `aliasStem` honours it |
| 3 | `HangarCore/SSHConfigImport.swift` | new: parser, tag derivation, skip reporting |
| 4 | `HangarCore/HostsFile.swift` | new: CSV reader, refusals with line numbers |
| 5 | `HangarCore/SigV4.swift` | signed content type and extra headers |
| 6 | `HangarCore/SSM.swift` | new: DescribeInstanceInformation |
| 7 | `HangarCore/HangarConfig.swift` | the `sources` block, hosts file path |
| 8 | `HangarCore/SSHConfigWriter.swift` | skip sources that do not write; source in comments |
| 9 | `HangarCore/Preflight.swift` | `sourcesCheck` |
| 10 | `Hangar/FleetStore.swift` | gather, merge, per-source reporting, SSM fallback |
| 11 | `Hangar/SetupWindow.swift` | the source list, drag and drop |
| 12 | `Hangar/Rows.swift` | source shown on a row that is not from EC2 |
| 13 | `Tests/*` | import, CSV, merge, SSM parsing, writer exclusion |
| 14 | `README.md`, `site/index.html` | four sources, and what each needs |

Proven by: the new tests, and `scripts/testbed.sh` driving a real Hangar against
a fabricated home directory with a 60-host ssh config and a CSV, touching
nothing in the developer's own `~`.
