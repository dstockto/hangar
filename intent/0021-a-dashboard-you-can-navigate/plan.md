# 0021 plan

| Order | File | Change |
|---|---|---|
| 1 | `HangarCore/ClusterFocus.swift` | new: the path, entering, opening, leaving, `nextKey`, `matches`, `backDestination` |
| 2 | `HangarCore/InstanceType.swift` | `sizeWeight` and `shortSize`, for a circle drawn as the machine |
| 3 | `HangarCore/Models.swift` | keep the rest of the DescribeInstances fields: AMI, VPC, subnet, key pair, IAM profile, security groups, lifecycle, cores, monitoring, root device |
| 4 | `Hangar/ClusterView.swift` | one level at a time, tier bands, host circles, the hub as the way back, every circle an accessibility button |
| 5 | `Hangar/DashboardWindow.swift` | Fleet and Insights tabs, the sidebar cards, the host record, the back button on Insights |
| 6 | `Hangar/Notifier.swift` | size the card from its text column plus its padding |
| 7 | `Tests/ClusterFocusTests.swift`, `Tests/InstanceTypeTests.swift` | the cases in the spec |
| 8 | `README.md`, `site/index.html` | the dashboard, the drill, the host record, and that `ec2:DescribeInstances` is the only permission |

Proven by: the new tests, the cluster driven through its accessibility tree
against a fictional fleet, and the notice card measured rather than eyeballed.
Steps 1 to 5 landed across `2c70688..07d0cf7`; 6 to 8 are this change.
