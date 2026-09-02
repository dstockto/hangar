# 0020: a dashboard for the fleet you already fetched

## How this came about

> I am assuming you are using ec2 describe instance bulk api to create our host
> list inventory, is there anything useful we can show like on a new app
> dashboard (combine the setup screen) to emit useful info for SREs ?
>
> perhaps an tab showing instances like this style ? https://gource.io/ clusters ?
>
> curious on what would be very helpful for SREs

The assumption is right: one paginated `ec2:DescribeInstances`, filtered to
pending, running, stopping and stopped. What is not obvious is how much of that
response Hangar throws away. It parses and caches the instance id, type, launch
time, private and public addresses, state, availability zone and every tag, then
uses about a third of it: tags for grouping and aliases, state for the glyph, a
hostname tag or the private address to connect. The rest sits in
`~/.hangar/cache/instances.json` costing nothing and saying nothing.

## What an SRE can be told for free

No new call, no new IAM permission, nothing that slows a refresh:

- **Tag hygiene.** Hosts missing the mapped product, env or name; hosts with no
  hostname tag, which can only be reached by private address; duplicate names
  inside one product and env, which make an ambiguous alias. This one improves
  Hangar's own output, not only the view of it.
- **AZ spread and ASG coverage.** Which availability zones each product and env
  actually occupies, and how many of its instances are in an autoscaling group.
  A service wholly inside one AZ is a finding. Pets in production are the hosts
  that page someone.
- **Age and instance families.** Uptime buckets from launch time, the cheapest
  proxy there is for AMI drift, and the instance type mix with previous
  generations and burstables called out.
- **Fleet delta and public addresses.** "223 to 209 since 14:02", from a short
  history kept alongside the cache, and which hosts hold a public address,
  grouped by environment.

## The cluster view

Gource animates history: its charm is commits arriving over time. Hangar holds a
point-in-time inventory, so a faithful clone would animate nothing on first
launch. The decision, made with that stated: build the animated cluster anyway,
because the shape of a fleet is worth feeling and not only reading, but drive it
from the structure rather than pretending to have a history. Products and
environments are nodes that find their own positions; hosts orbit the
environment they belong to; colour carries state. Once the refresh history has
a few points in it, arrivals and departures animate honestly.

## Constraints

- **One API call.** Everything above is derived from the response Hangar already
  has. Anything that would need volumes, metrics or cost data is out, because
  "one read-only AWS call" is a claim on the landing page and in `SECURITY.md`.
- **A separate window.** The setup screen stays what it is: a readiness check
  someone reads once. The dashboard is a different question asked repeatedly.
- **The analytics are UI-free.** Every number here is computed in `HangarCore`
  and tested there. The window draws what the core says.
