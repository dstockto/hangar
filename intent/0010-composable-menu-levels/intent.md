# 0010: whose grouping is this

## How this came about

Three questions in a row, each one narrowing the last, while the tag picker from
0009 was still being built:

> on the tag catalog, not every company uses product, environment,
> environment_name, Role, etc., leave them as top level grouping etc.

> they can also only do 1 grouping? we have three or 4 levels here .....

> yeah, give user the ability to add levels, and map levels to submenus ...
> perhaps?

The first is about labels. The second found a bug. The third is the real design.

## The labels

The picker asked for "Product", "Environment", "Environment name" and "Role".
Those are one industry's vocabulary. A fleet organised by team, business unit or
service has the same levels under different words, and being asked to fill in
"Product" when you have no such concept is a small barrier that arrives at
exactly the wrong moment, thirty seconds into a first launch.

Renamed by what each one does: "Top-level grouping", "Second grouping", "Third
grouping", "Host label", "Address to connect to", with the common tag names moved
into the explanation as examples rather than presented as the answer.

## The bug the second question found

Asking "can they do only one grouping?" turned up that they could configure it
and the menu would not honour it. `addFleet` grouped by product and then by env
unconditionally. A fleet with one grouping got a real level, then a second level
containing a single "untagged" entry containing everything: a click that costs a
click and carries no information.

Verified against the real 249-host fleet afterwards: one level produces depth 1
with 5 top-level groups; no grouping produces a flat list; every configuration
keeps all 249 hosts.

## The design the third question asked for

Levels were three fixed ideas. They are now an ordered list of tag keys:

```json
"group_by": ["Team", "Environment"]
```

Consequences worth stating:

- **Any tag key works**, not only the five Hangar maps. A fleet grouping by
  Region has never needed Hangar to have an opinion about regions.
- **Order is the menu order**, so the same two keys give two different menus and
  the user picks which.
- **A level no host carries adds no submenu**, which is what makes a
  half-configured list behave sensibly rather than producing empty levels.
- **An empty list is a legitimate choice**, a flat list of every host, which is
  the right answer for a small fleet and was previously impossible.
- The default stays `["product", "env", "env_name"]`, so nothing changes for a
  fleet that was already working, and a config predating the key keeps grouping.

## Why the grouping moved into the core

It was computed inline in `MenuBarController` while building `NSMenu`, which is
why the empty-level bug survived: the only way to see it was to open the menu and
look. `FleetGrouping` returns a tree, so the shape of the menu is asserted rather
than eyeballed, and "every host survives whatever the levels" is a test rather
than a hope.

## Proof

`FleetGroupingTests`, 13 cases: one grouping gives one level, none gives a flat
list, a partly-tagged level keeps its untagged bucket, arbitrary keys work, order
matters, a configured key nothing carries adds no level, canonical and raw
spellings both resolve, and no host is lost under any of five level
configurations.
