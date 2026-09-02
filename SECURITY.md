# Security

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on
[this repository](https://github.com/goriparthi/hangar/security/advisories/new).
Please do not open a public issue for a vulnerability.

Include what you did, what happened, and the Hangar version from **About Hangar**.
Expect a first reply within a week.

## What Hangar touches

Worth knowing before you look for holes, and worth checking if you are evaluating
whether to run it:

- **Reads** `~/.aws/config`, `~/.aws/credentials`, the SSO token cache in
  `~/.aws/sso/cache`, and `~/.hangar/config.json`.
- **Writes** `~/.ssh/config.d/hangar` and `~/.hangar/`, both at `0600` inside `0700`
  directories. It refreshes the SSO token cache in place, in the AWS CLI's own
  format, when the access token has expired.
- **Adds one line** to `~/.ssh/config`, and only from the explicit menu action,
  which keeps a backup first.
- **Talks to** `ec2.<region>.amazonaws.com` for the fleet, plus
  `sts.`, `oidc.` and `portal.sso.` when the profile needs them, and
  `api.github.com` only when you ask it to check for updates. There is no Hangar
  server, account, or telemetry.
- **Never reads private keys.** Key material stays with `ssh` and your agent.
- **Runs `credential_process`** through `/bin/sh` when a profile configures one,
  exactly as the AWS CLI does. That command comes from your own `~/.aws/config`.
- **Executes `ssh`, `hdiutil`, `codesign`, `spctl` and `ditto`** by absolute path,
  with arguments passed as an argument vector rather than through a shell. Where a
  hostname is followed by another argument, `--` precedes it: an argument vector
  alone does not stop `ssh` from reading a host that begins with `-o` as an
  option.

## Removing it

**Settings → Reset Hangar** removes everything Hangar wrote: `~/.hangar/` and the
generated `~/.ssh/config.d/hangar`. It does not remove the `Include` line from
your `~/.ssh/config`, which is yours and is harmless pointing at nothing, and it
never touches `~/.aws` or your keys. Deleting the app and that directory leaves
nothing behind.

## Untrusted input

Instance tags are written by anyone who can tag the account, so they are treated
as untrusted:

- Values written into `ssh_config` are quoted, and any value containing a newline,
  carriage return, NUL, or double quote is dropped rather than written. That host
  is reported as skipped rather than silently omitted.
- Names on a `Host` line are held to a stricter rule than values, because that
  line is a pattern list: only letters, digits, dot, hyphen and underscore, and
  never a leading hyphen. A tag of `*` would otherwise become a catch-all that
  outranks every entry in the user's own `~/.ssh/config`.
- Values interpolated into the `ssh` command handed to a terminal are shell-quoted,
  and a command containing a line break is refused.
- Region names are validated before they reach an endpoint hostname.

## Updates

An update is installed only when **both** hold:

- `spctl -a -t exec` accepts the bundle, meaning Apple notarized it.
- `codesign -R` verifies it against a pinned requirement,
  `anchor apple generic and certificate leaf[subject.OU] = "QX3NQYWX6F"`.

The second is a cryptographic requirement rather than a grep of codesign's output,
because that output contains the app's filename, which a hostile DMG author picks.
Both the mounted image and the staged copy are verified. The installed app is moved
aside, not deleted, so a failed swap can be rolled back.

## Supported versions

The latest release is the supported version.
