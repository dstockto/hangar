# 0003: whose fleet is this for

## How this came about

One question, asked during a review of something else entirely:

> what happens right now if there are no instance tags on the EC2 side? how does
> the app react? can it work with env, product, env_name etc? if someone
> downloads this for their needs would this work?

The honest answer was no, for most fleets. That answer cost a sentence to obtain
and would have cost the project its first ten users to learn the other way.

## What was actually true

Hangar read four tags to group and name hosts: `product`, `env`, `env_name` and
`Name`. Those are one organisation's convention, hardcoded. Traced through:

- A fleet tagged `Service` / `Environment` / `Component`, which is at least as
  common, resolved nothing. Every host grouped under "untagged" and was named by
  its instance id.
- A wholly untagged instance fell back to its id for the alias stem and then had
  the id appended again, producing `i-0abc123def-i-0abc123de`.
- The setup check reported "hosts have no product or env tags", which is a
  statement of fact and no help at all: it named neither the keys Hangar looks
  for nor anywhere to change them.

The app ran. It was useless to anyone who was not its author. That is a harder
failure to notice than a crash, because nothing looks broken.

## The design question

Whether to widen the guesses or make them configurable. Both: a list of candidate
keys per idea, tried in order and matched case-insensitively, with defaults broad
enough that the common conventions work untouched, and a config block for a fleet
that uses something else.

The decision that mattered was **where** to apply it. Threading a mapping through
every screen would have touched everything. Normalizing at the boundary instead,
rewriting an instance's tags so the canonical keys carry the resolved values,
meant nothing downstream changed at all. The original tags are kept, so a filter
or an override can still name any tag the instance actually has.

One consequence had to be handled: a cached instance normalized under an old
mapping must not outvote a new one, so a canonical key that resolves to nothing
is removed rather than left.

## What was left for later

The defaults are still a guess. Discovering the fleet's real keys and letting the
user pick from them is 0009, and it is the better answer; this is the floor.

## Proof

`TagMappingTests`, and the tests are as much the deliverable as the code, because
the claim being made is "this works for fleets we have never seen": Environment
and Service with no configuration, uppercase keys, app and stage, a single `Name`
tag, nothing at all, and a custom mapping naming `BusinessUnit`.
