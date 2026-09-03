# 0024 spec: host sources

## Provenance

```swift
public enum HostSource: String, Codable, Sendable, CaseIterable {
    case ec2, ssm, sshConfig = "ssh_config", hostsFile = "hosts_file"

    /// Whether Hangar writes this host into ~/.ssh/config.d/hangar. False for
    /// ssh_config: those hosts are already resolvable and rewriting them would
    /// put Hangar's copy above the user's own definition.
    public var writesSSHConfig: Bool { self != .sshConfig }
}
```

`Instance` gains two optional fields, optional so a cache written before this
keeps decoding:

```swift
public var source: HostSource?          // nil means .ec2
public var preferredAlias: String?      // set by non-EC2 sources
```

`aliasStem` returns `preferredAlias` verbatim when set. Verbatim, not slugified:
for an imported host it is the name ssh already resolves, and changing it would
produce an alias that does not work.

## Source 1: `~/.ssh/config`

`SSHConfigImport.hosts(from:)` walks the file and returns `[Instance]` plus a
list of what it skipped and why.

Parsed:

- `Host` lines, taking every name on the line; the first is the alias, the rest
  become extra search terms.
- `HostName`, `User`, `Port` from the block, first value wins, matching ssh.
- `Include` directives, followed relative to `~/.ssh`, with a depth cap of 8 and
  a visited set, because an include loop is a plausible hand-edit.

Skipped, and reported:

- Hangar's own file, matched by path, so the fleet never imports itself.
- Any name containing `*`, `?` or `!`. A pattern is not a host.
- `Match` blocks in their entirety. They cannot be evaluated statically, and
  guessing produces an alias that resolves to something else.
- Any name failing `SSHConfigValue.isSafeAlias`.
- A block with no `HostName` and an alias that is not itself a usable hostname.
- **Git remotes.** Found on the first real run: a developer's config had entries
  for GitHub and Bitbucket, and both were imported as hosts, sorted to the top of
  the panel because they carry no product, and could never be connected to.
  `ssh git@github.com` prints a greeting and exits. The rule is `User git`, which
  covers every self-hosted GitLab, Gitea and Forgejo as well, plus a list of forge
  hostnames for entries that leave `User` to the remote URL. A machine merely
  named for git and logged into as a person is still a host.

Tags are derived by splitting the alias on `.` and `-`, because that is how
people already name things:

| Alias | product | env | role |
|---|---|---|---|
| `payments-prod-web-1` | payments | prod | web-1 |
| `web1.prod.example.com` | example | prod | web1 |
| `bastion` | (none) | (none) | bastion |

`env` is only assigned when a component matches a known environment word (prod,
production, stage, staging, qa, uat, dev, test, sandbox, preprod, perf). Anything
else is guessing, and a wrong env on a production box is worse than none. Every
imported host also carries `ssh_config_user` and `ssh_config_port` tags so an
override can match on them.

The `User` found in the block becomes the instance's login, and the writer never
writes it because the writer never writes this source at all.

## Source 2: `~/.hangar/hosts.csv`

`HostsFile.parse(_:)` reads a header row and one host per line.

- Required: `alias` or `hostname`; whichever is missing is filled from the other.
- Recognised: `alias`, `hostname`, `user`, `port`, `product`, `env`, `role`,
  `state`.
- Every other column becomes a tag under its own header name, so a fleet with
  `datacenter` or `owner` columns keeps them and can group by them.
- Blank lines and lines beginning `#` are skipped.
- Quoted fields with embedded commas and doubled quotes are handled; this is a
  file people export from a spreadsheet.

A row whose alias fails `isSafeAlias`, or whose hostname fails `isEmittable`, is
refused **with its line number**. The result carries both the hosts and the
problems, and the setup screen shows the first few rather than a count.

Ids are `csv:<alias>`, stable across re-imports so an override that pins one
keeps working.

Importing a CSV means copying it to `~/.hangar/hosts.csv` through `PrivateFile`.
Drag and drop onto the setup window or the dashboard does exactly that. The file
is re-read on every refresh, so nothing is cached that the user cannot see.

## Source 3: `ssm:DescribeInstanceInformation`

`SSM.describeInstanceInformation()` posts AWS JSON 1.1 to
`ssm.<region>.amazonaws.com` with `X-Amz-Target:
AmazonSSM.DescribeInstanceInformation`, paginating on `NextToken`.

`SigV4.sign` grows a `contentType` and an `extraHeaders` parameter, both signed,
because `x-amz-target` must be in the canonical headers or the signature is
rejected.

Mapped per entry: `InstanceId` to id, `IPAddress` to `privateIP`,
`ComputerName` to the `Name` tag and to `hostname` when it looks like an FQDN,
`PlatformName` and `PlatformVersion` to `platform`, `PingStatus` to state
(`Online` becomes `running`, anything else `unknown`). On-prem managed instances
have `mi-` ids and are kept; they are exactly the hosts EC2 could never show.

It runs only when `DescribeInstances` fails with an authorization error, or when
`sources.ssm` is explicitly true. A fleet with EC2 access pays nothing for it.

## Merging

`FleetMerge.merge(_:)` takes source groups in priority order and returns the
merged fleet plus the count dropped as duplicates.

Priority: `ec2`, `ssm`, `hostsFile`, `sshConfig`.

A host is a duplicate of one already taken when it matches on any of: instance
id, resolved hostname, or alias. First one in wins, so a host EC2 knows about
keeps its tags and its dashboard data even if `~/.ssh/config` also names it.

## Configuration

```json
"sources": {
  "ec2": true,
  "ssm": null,
  "ssh_config": true,
  "hosts_file": true
}
```

`null` for `ssm` means "only when EC2 is denied", which is the default. All four
default on, because a source that finds nothing costs nothing and a source the
user has to discover is a source they never turn on.

## What the setup screen shows

The **Hosts and keys** card gains a source list above the key half:

```
Hosts
  ✓ EC2                     0 hosts     ec2:DescribeInstances denied
  ✓ Systems Manager         31 hosts    tried because EC2 was denied
  ✓ ~/.ssh/config           41 hosts    launch only, not rewritten
  –  ~/.hangar/hosts.csv    none yet    Drop a CSV here
```

The denied row is no longer a dead end: it sits directly above two sources that
found hosts.

## Insights degrade honestly

`FleetInsights` is computed over instances that carry the field it needs, and
each panel reports its own denominator. A fleet of 41 imported hosts shows
"placement: no data for 41 hosts" rather than one bar reading zero.
