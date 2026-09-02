# 0020 plan

| Order | File | Change |
|---|---|---|
| 1 | `HangarCore/FleetInsights.swift` | new: hygiene, placement, ages, families, exposure |
| 2 | `HangarCore/InstanceType.swift` | new: family, generation, size, burstable, previous generation |
| 3 | `HangarCore/HangarConfig.swift` | `Cache.history`, capped at 60 samples |
| 4 | `Hangar/FleetStore.swift` | append a sample per successful refresh; expose insights |
| 5 | `Hangar/ClusterView.swift` | new: the animated cluster |
| 6 | `Hangar/DashboardWindow.swift` | new: window, panels, footer |
| 7 | `Hangar/MenuBarController.swift` | Dashboard… item |
| 8 | `Tests/FleetInsightsTests.swift`, `Tests/InstanceTypeTests.swift` | the cases in the spec |
| 9 | `README.md` | what the dashboard shows and that it needs no new permission |

Proven by: the new tests, and the window driven against the demo fleet with the
panels read back through the accessibility tree.
