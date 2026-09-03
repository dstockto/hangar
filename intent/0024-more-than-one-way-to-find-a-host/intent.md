# 0024: more than one way to find a host

## How this came about

> Also when doing auto discovery, if an SRE doesn't have describe instance
> permission, should be look at their current ssh config to ingest that and use
> those hosts as TLD ? want this to work for more than EC2 Describe Instance
> Permission + Current User + Key in home dir ....
>
> Perhaps let them import a CSV with hostnames ?

## What was actually true

Hangar had exactly one way to find a host, and three assumptions baked around it.

1. **`ec2:DescribeInstances` or nothing.** A refusal produced an empty fleet and
   a red credentials card. For an SRE whose account grants Session Manager but
   not EC2 read, that is a dead end on first launch, and the app looks broken
   rather than under-permissioned.
2. **The current user is the login.** `HangarConfig.standard()` sets
   `user: NSUserName()` and the writer emits it for every host, so someone who
   logs in as `ec2-user` gets `User pgoriparthi` on all of their aliases until
   they find `~/.hangar/config.json`. The information to do better was sitting in
   their own `~/.ssh/config` the whole time.
3. **The key is a file in the home directory.** Handled by
   [0023](../0023-a-key-you-never-have-to-name/intent.md).

The deeper thing: "the fleet" was the `DescribeInstances` response. Everything
downstream, aliases, grouping, search, insights, was written against that one
shape without anyone deciding it should be the only shape.

## What was decided

**EC2 becomes one source of hosts, not the source.** `Instance` already carries
what a host needs: an id, tags, a hostname, a state. A `HostSource` tag on it,
plus a merge with a stated priority, is all it takes for four sources to feed one
fleet.

**`~/.ssh/config` is imported, and nothing is written back.** This is the whole
design of it. Those hosts are already resolvable by ssh, so Hangar indexes them
for search, grouping and launch and stays out of the file completely. No
duplicate `Host` blocks, no first-match-wins fight with the user's own config,
no chance of Hangar's Include shadowing something they wrote by hand years ago.
An imported host is launchable but not writable, which is a distinction the
writer already had a shape for.

It also answers assumption 2 for free: an imported host brings its own `User`,
which is a fact rather than a guess.

**A hosts file, and CSV import means writing it.** The static source is
`~/.hangar/hosts.csv`, not an import wizard with a hidden database behind it.
Then a script, a cron job, an Ansible inventory export or a Netbox query can all
feed it, and it is hand-editable and inspectable exactly like `config.json`
already is. Dragging a CSV onto the Hangar window copies it there. The file is
watched, so re-exporting refreshes the fleet without touching the app.

**`ssm:DescribeInstanceInformation` as the AWS fallback.** Plenty of SREs have
Session Manager without EC2 read. It is a plain SigV4 JSON call, so no SDK and no
CLI, and it returns instance id, computer name, IP address and platform. It is
tried automatically when `DescribeInstances` comes back denied, which is the
"it should just work" behaviour: the user never learns the name of the API that
failed.

Using SSM as *transport* was considered and rejected for now. `ProxyCommand aws
ssm start-session` needs the AWS CLI and its session-manager plugin at runtime,
and "no runtime dependency on the aws CLI" is a product property. Discovery is
free; transport is a separate decision that deserves its own intent.

## What this breaks if it is done carelessly

- **The dashboard is EC2-shaped.** AZ spread, instance families and ages come
  from fields an imported host does not have. Showing zeros would be mistake 18
  again: two things answering the same question differently. Insights are
  computed over the hosts that carry the data, and say how many they are.
- **Alias collisions across sources.** Stated priority: EC2, then SSM, then the
  hosts file, then `~/.ssh/config`. A host already present under the same
  instance id, the same alias or the same address is not added twice.
- **Provenance has to be visible.** Every row and every generated comment says
  which source a host came from, because "where did this come from" is the first
  question anyone asks about a host they did not expect to see.
- **Imported config is untrusted input.** `~/.ssh/config` is hand-edited and a
  CSV arrives from anywhere. Both go through `SSHConfigValue` before they reach a
  file or a command, same as an EC2 tag, and anything unusable is reported rather
  than dropped.
