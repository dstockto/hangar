# Intent: work with a fleet that is not ours

## Problem

Hangar reads four tags to group and name hosts: `product`, `env`, `env_name` and
`Name`. Those were hardcoded, and they are one organisation's convention. A fleet
tagged `Service` / `Environment` / `Component`, which is at least as common, gets
every host grouped under "untagged" and named by instance id. The app runs and is
useless.

This was found by asking the question directly: if someone downloads this for
their own fleet, does it work? For most fleets, no.

## Outcome

Hangar works on first launch for the tag conventions in common use, and a fleet
using something else says so in one config block instead of retagging instances.

## Affected

Every user who is not the author. This is the difference between a personal tool
that happens to be public and something someone else can use.

## Constraints

- No change for a fleet already tagged the way Hangar expected.
- The original tags stay readable, because filters and overrides can name any tag
  an instance actually has.
- A stale cache written under one mapping must not outvote a new mapping.

## Out of scope

Tag-based filtering beyond what hotkey filters already do.
