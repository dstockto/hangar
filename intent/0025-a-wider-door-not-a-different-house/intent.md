# 0025: a wider door, not a different house

## How this came about

> now update all marketing site and readme to reflect these new capabilities and
> what this tool is now capable off, see if need to pivot the story wholistically
> as this goes from an SRE niche tool to mainstream SSH manager

## The question under it

[0024](../0024-more-than-one-way-to-find-a-host/intent.md) removed the last hard
requirement. Hangar now needs no AWS account, no IAM permission and no tags to be
useful: it reads the hosts already in `~/.ssh/config` and any CSV you hand it. The
addressable user went from "an SRE with `ec2:DescribeInstances`" to "anyone with
more than a handful of ssh hosts".

So: is Hangar now a mainstream SSH manager, and should the copy say so?

## What was decided: no

Repositioning as an SSH manager would be a downgrade, for three reasons.

**The category is commoditized.** Termius, Royal TSX, SecureCRT, Shuttle, and
iTerm profiles all "manage your ssh hosts". Competing there means competing on a
claim that is true of a dozen products and differentiating on none of them.

**It undersells the only part nobody else does.** Aliases derived from instance
tags, which survive the instance being replaced; a tag mapping that adapts to a
fleet's own vocabulary; composable menu levels; a dashboard computed out of the
same `DescribeInstances` response. That work is fleet-shaped, and "SSH manager"
describes none of it.

**The new sources are a thinner slice of value than the old one.** A host
imported from `~/.ssh/config` gains search, grouping and a global shortcut, which
is real. It does not gain an alias that maintains itself, because Hangar
deliberately does not write those hosts. The EC2 story remains the deep one.

## What actually changed is the door, not the house

The old copy put a permission in front of the product. "Hangar turns changing EC2
instances into stable, searchable SSH targets" tells a reader with no AWS account
that this is not for them, on the first line, which is now false.

So the story becomes a ladder rather than a pivot:

1. **Any ssh user.** The hosts you already have, searchable, behind one shortcut.
   Nothing to configure, no permission, works on first launch.
2. **Anyone with an inventory.** Drop a CSV. A spreadsheet, an Ansible export, a
   CMDB query.
3. **An AWS fleet.** Aliases that follow the tags rather than the hostname, and
   the dashboard over the call you already made.

Every rung is honest on its own, and each one is a reason to climb to the next.
The headline keeps the shortcut, because that is the thing Hangar owns, and drops
the word that gated it.

## Copy changes

| Where | From | To |
|---|---|---|
| Site `<h1>` | Your fleet, one keystroke away. | Every host you can ssh to, one keystroke away. |
| Site lede | turns changing EC2 instances into… | reads the hosts you already have *and* the fleet you cannot keep up with |
| `<title>`, `og:` | fleet-first | host-first |
| Proof strip | `AWS CLI: Not needed to run` | adds `AWS: Optional` and `Sources: 4` |
| README subtitle | EC2-first sentence | the ladder, in three lines |
| CLAUDE.md | "turns changing EC2 instances into…" | the same widened sentence |

What does **not** change: the before-and-after comparison, the dashboard
sections, the tag mapping documentation, or the security page. Those are the
house, and the house is fine.
