# 0021 spec: drilling, the host record, and the way back

Supersedes the "The window" and "The cluster view" sections of
[0020's spec](../0020-fleet-dashboard/spec.md). `FleetInsights`, the history and
the performance budget in that document are unchanged.

## The focus, in the core

`ClusterFocus` holds where the view is, and is the only thing that decides which
hosts are on screen. UI-free and tested, because "which hosts am I looking at"
has a right answer.

```swift
public struct ClusterFocus: Equatable, Sendable {
    public var path: [String]      // one value per grouping level entered
    public var hostID: String?     // set when one host is open
}
```

- `entering(_:)` goes one level deeper, `opening(host:)` opens an instance, and
  `leaving()` steps out by one, from a host back to the group it was in and from
  a group back towards the fleet. The fleet is the floor: leaving it is a no-op
  rather than an invalid state.
- `nextKey(_:)` is the grouping key a click at this depth would open, and nil
  once the next click opens a host rather than another group. That is what makes
  the drill follow `group_by` rather than an assumption about product and env.
- `matches(_:groupingKeys:)` compares tag values level by level, so a fleet
  grouped by `["Team"]` drills by team.
- `backDestination` is the label of the level a step out lands on: nil at the
  fleet, empty when back is the fleet itself, otherwise the parent's label. It
  exists so a control can be named after where it goes instead of "Back".

## The three levels

The cluster shows exactly one level, chosen by the focus.

1. **Groups.** One circle per distinct value of `nextKey`, radius
   `9 + 6 * sqrt(count)` capped at 52, so area tracks host count. Hosts appear
   as particles on an arc beside their group, positioned from a hash of the
   instance id so the picture is stable between refreshes.
2. **Groups again**, one level down, when `group_by` has another key. Tier
   orders the ring: production nearest the hub, then staging, test, development,
   other, each tier a band further out. Within a tier the order is alphabetical,
   so each band forms an arc and the same fleet lands in the same picture.
3. **Hosts**, once there is no key left or the group holds a single instance.
   One circle per instance, radius `min(46, 9 + sqrt(sizeWeight) * 5)` from
   `InstanceType.sizeWeight`, with the short size drawn inside it: `8xl`, `lg`,
   `md`. Colour is state. The label under each circle is the host's leaf name.

Colour follows what the circle is: a group takes its product's category hue, a
host takes its state, and the particles beside a group take theirs. None of it is
load bearing. The count is inside every group circle, the name is on it or one
hover away, and the panels say the same things in words.

`sizeWeight` is derived from the size suffix alone, which is all
`DescribeInstances` gives without a second API: `large` is 4, an `n`xlarge is
`8n`, `metal` is 192 as a deliberate approximation, and an unrecognised suffix
sits at 3 so an unfamiliar family neither dominates the picture nor vanishes.

## Getting back out

Three ways, all the same operation, so there is one implementation:

- **The hub.** Clicking the circle in the middle steps out one level. Its label
  says where that is: `payments · prod · back`, or the region at the fleet.
- **The hub as an accessibility button**, titled "Back to payments · prod", so
  the picture is navigable without a mouse and testable without clicking pixels.
- **A button at the top of the Insights tab**, present whenever the focus is not
  the whole fleet, titled the same way. The Insights tab does not show the hub,
  and a screen with no exit on it is a trap. This is the fix for the question in
  the intent.

Refreshing while drilled keeps the focus, unless what was open is no longer in
the fleet, in which case the view falls back to the whole fleet rather than
showing an empty ring.

## The window

Two tabs in the title bar, one sidebar, one action.

- **Fleet** is the cluster, filling the window.
- **Insights** is the panel column. Both are the same data; only one is on
  screen at a time so neither is cramped.
- **The sidebar** carries four cards: total hosts, running with its share,
  stopped, and groups with whether the tags are clean. Below them a state rail
  and the cache age, and at the bottom **Refresh Fleet**. Every card describes
  the current focus, not the account, so drilling into `payments · prod` shows
  that group's counts.

## The host record

With one host in focus, the Insights column is that instance instead of
statistics about a sample of one:

State with its reason if any, launch time as an age and a date, instance type
with vCPUs and architecture, instance id, availability zone, VPC, subnet,
private address, private DNS, public address when it has one, hostname tag, AMI,
key pair, IAM instance profile, security groups, lifecycle when it is spot or
scheduled, monitoring, root device, autoscaling group or "none, this one is a
pet", and the ssh alias Hangar generated. Then every tag, sorted, because the
one you need is always the one a summary dropped.

Each field is shown only when the response carried it. Nothing is inferred and
nothing is fetched.

## The notice card

A notice is sized from its text column plus its padding, both constants, rather
than from `NSStackView.fittingSize`, which reports the cross-axis width without
the stack's own `edgeInsets` and so produced a card with no padding at all. The
column is at most 300 points and at least 210, the padding is 26 horizontal and
20 vertical, and both the title and the body wrap inside the column.

## Tests

`ClusterFocusTests` covers the fleet, entering each level, opening a host,
leaving one level at a time down to the floor, that the levels come from the
configured keys rather than the defaults, and that `backDestination` names the
right place at every depth. `InstanceTypeTests` covers `sizeWeight` and
`shortSize` including a malformed type string.

The window itself is proven by driving it: every circle and the hub are
accessibility buttons, so the drill is exercised by pressing elements rather
than by clicking coordinates, which is the only thing that works when another
window is in front.
