# Spec: public release hardening

## Untrusted tag values

EC2 tag values may contain spaces, and Hangar interpolates them into `ssh_config`
and into a command typed into a live shell.

- Values written into `ssh_config` are wrapped in double quotes when they contain
  whitespace. `HostName "web 1.example.com"` parses; the unquoted form makes `ssh`
  reject the entire file.
- A value containing a newline, carriage return, NUL or double quote cannot be
  represented and is refused. The affected host is omitted from the file and
  reported through `SyncResult.omittedHosts`, so the caller can say so.
- An unusable value in an override drops that one option, not the host.
- Values reaching a terminal command are shell-quoted; a command containing a
  line break is refused before it reaches AppleScript.

## Region validation

A region name is lowercase alphanumerics and hyphens. Anything else is rejected
with a message naming the file to fix, rather than trapping on a nil `URL`.

## Credentials at rest and in flight

- The fleet cache is `0600`, matching the rest of `~/.hangar`.
- The refreshed SSO token file is created at `0600` before the write, not chmodded
  after, so it never exists at the process umask.
- AWS calls use an ephemeral `URLSession` with no disk cache and no cookie store.

## Updater integrity

- `spctl -a -t exec` and a pinned `certificate leaf[subject.OU]` requirement, both
  run against the mounted image and against the staged copy.
- `ditto`, not `cp -R`, for the bundle copy.
- The installed app is moved aside and restored on failure, never deleted first.

## Repository

- `bin/hangar` is removed.
- CI runs build, test and bundle on every pull request.
- `SECURITY.md` describes what Hangar reads, writes and talks to, and routes
  vulnerability reports privately.
- The test suite runs under `swift test`.

## Acceptance

- A tag containing a space produces a file `ssh -G` accepts, with both hosts.
- A tag containing a newline produces a file with no `ProxyCommand` in it, and the
  host reported as skipped.
- A malformed region produces a readable error, not a crash.
- Re-signing a bundle ad hoc makes the updater refuse it.
