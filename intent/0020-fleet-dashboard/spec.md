# 0020 spec: the fleet dashboard

## The core: `FleetInsights`

One value type computed from `[Instance]` plus the tag mapping, no AppKit, fully
tested. Every field below is derived from a `DescribeInstances` response Hangar
already holds.

```swift
public struct FleetInsights: Sendable, Equatable {
    public var hygiene: Hygiene
    public var placement: [GroupPlacement]     // one per product+env
    public var ages: [AgeBucket]
    public var families: [FamilyUse]
    public var exposure: [ExposureByEnv]
    public var total: Int
    public var running: Int
    public var stopped: Int
}
```

**Hygiene.** `missingProduct`, `missingEnv`, `missingName`, `missingHostname`,
`duplicateAliases: [String: Int]`. Missing means the mapped key resolves to an
empty string, so it follows the user's tag mapping rather than assuming ours.
A duplicate alias is two instances whose `aliasStem` collides.

**Placement.** Per product and env: instance count, the set of availability
zones, how many carry `aws:autoscaling:groupName`. `isSingleZone` is true when a
group has more than one instance and one zone; a single host cannot be spread.

**Ages.** Buckets from `launchTime`: under a day, under a week, under a month,
under 90 days, under 180, over 180. An unparseable launch time counts as unknown
rather than as new, because guessing young is the flattering answer.

**Families.** `m6i.large` yields family `m6i`, generation 6, size `large`.
Previous generation means the trailing digit is below the current one for that
letter series, computed from a small table that is easy to keep true rather than
from a live API. Burstable is the `t` series. Both are reported as counts, never
as advice: Hangar does not know why a `t3.micro` is in production.

**Exposure.** Per env: how many instances hold a public address. The addresses
themselves are not listed in the panel; a count and a way to filter the panel to
them is the useful part, and it keeps the screen safe to screenshot.

## History, for the delta

`Cache` gains `history: [Sample]`, a `Sample` being a timestamp and a host count,
appended on every successful refresh and capped at 60 entries, which is about a
day and a half at the default refresh. It costs a few hundred bytes and answers
"has the fleet moved". The dashboard shows the newest delta as text and the
series as a sparkline. A cache written by an older Hangar has no history and the
panel says so rather than inventing a flat line.

## The window

`DashboardWindow`, opened from the menubar, remembered frame, standard window so
it appears in the app switcher like the setup screen. Top to bottom:

1. **The cluster**, at least a third of the height, resizing with the window.
2. **Four panels** in a scrolling column, in the order the intent lists them.
   Each panel is a heading, a headline number, and the rows behind it. Every
   number is a count with a noun; nothing is a percentage without its base.
3. **A footer** with the region, the cache age, and a refresh button.

## The cluster view

An `NSView` drawing with Core Graphics, driven by a display link, no dependency.

- **A hub.** One circle in the middle for the account's EC2 inventory, carrying
  the total and the region, with a spoke to every group. It is where the data
  came from, and it gives the layout something to orbit, so the picture reads as
  one fleet rather than as scattered blobs.
- **Nodes.** One per product, one per env inside it, `radius = 9 + 6 * sqrt(count)`
  capped at 52, so area tracks the host count and a group twice the size looks
  twice the size. Hosts are particles bound to their env node, not simulated
  individually: a force simulation over 2,847 bodies is a frame budget spent on
  nothing, since a host's position carries no information beyond which env it
  belongs to.
- **Layout.** Groups are sprung towards an orbit around the hub, repelled from
  each other, and pulled gently towards others of the same product. Host
  particles sit on a ring around their group, at an angle from a hash of the
  instance id, so the same host lands in the same place across launches and the
  picture is stable between refreshes.

  **Refined during build.** The orbit was first a fraction of the view, which
  worked at eight groups and failed at twenty-four: they piled onto one small
  circle and repulsion then shoved them off the edges. The radius now comes from
  what has to fit on it, the summed diameters plus a gap divided by 2π, clamped
  to the view.

- **Labels.** Only the largest groups are named, as many as the view can hold at
  one per 46 points, plus whichever is hovered. Two dozen labels around one ring
  overlap into noise, and every circle carries its count inside it either way.
- **Motion.** The simulation settles in about two seconds and then idles: no
  perpetual drift, because a picture that never stops moving is a picture nobody
  can read. Arrivals fade in and departures fade out over half a second when a
  refresh changes the fleet.
- **Colour.** State, from the brand palette: running, stopped, pending,
  terminated. Colour is never the only carrier: the legend names each state, and
  a hovered node shows a label with counts.
- **Reduced motion.** With `accessibilityDisplayShouldReduceMotion`, the layout
  is solved without animating and drawn once. The view is not the only way to
  read any of this; the panels below carry the same facts as text.
- **Accessibility.** The view is one accessibility element with a label that
  summarises the fleet, because a screen reader has no use for 2,847 unlabelled
  circles.

## Performance

At 250 hosts and 30 groups the simulation is 30 bodies, and drawing is 280
filled circles a frame. At 3,000 hosts it is still 30 bodies and 3,030 circles;
drawing is batched per state colour to keep it to a handful of Core Graphics
calls. The frame is skipped entirely when the window is not visible.

## Tests

`FleetInsights` against fixtures: hygiene counts including a duplicate alias, a
single-zone group with two hosts and a single-host group that is not flagged,
each age bucket boundary, family parsing including a malformed type string, and
exposure counts. Cache history: appended on refresh, capped, and an old cache
without it decodes.
