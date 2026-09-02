<div align="center">

<img src="site/assets/hangar-icon.png" alt="Hangar" width="128" height="128">

# Hangar

**Spotlight for your SSH hosts.**

A native macOS launcher that turns changing EC2 instances into stable, searchable
SSH targets.

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>H</kbd>, type a few characters, press
<kbd>Return</kbd>, and you are on the box.

### [Download Hangar](https://github.com/goriparthi/hangar/releases/latest)

Signed and notarized by Apple. Open the DMG, drag Hangar to Applications, launch it.
No Gatekeeper warning, no `xattr` command, no Homebrew, no Xcode.

</div>

---

## Why

Autoscaling should replace instances, not your memory. Instances in an
autoscaling group get machine-generated hostnames that change every time one is
replaced, so there is nothing to bookmark and nothing to remember. Finding the
box you need means running an AWS CLI query and copying a 58-character hostname
by hand.

Hangar indexes your tagged fleet, gives every host a stable alias, and puts the
right target one keystroke away.

## What it does

- **Global shortcut, fuzzy search.** A floating panel opens from anywhere. Terms
  match in any order, so `payments web qa` finds `payments-qa-web`.
- **Return connects** in iTerm2 or Terminal. <kbd>⌘</kbd><kbd>Return</kbd> copies
  the command for another tool instead.
- **Stable aliases everywhere.** Hangar writes an ssh_config include, so
  `ssh payments-prod-web-1` works from any terminal, and from `scp`, `rsync`,
  Ansible, and VS Code Remote.
- **Health at a glance.** The menubar aircraft turns green while the cache is
  fresh.
- **Fix a wrong login in place.** <kbd>⌘</kbd>-click a host to edit its ssh user
  or key, with a **Detect Login** button that probes the usual cloud-image logins
  and keeps the one that authenticates.
- **Menubar cascade** grouped product, environment, host.

## Install

**Download the DMG**, drag Hangar to Applications, and open it. That is the whole
install. The app is signed with a Developer ID certificate and notarized by Apple,
so Gatekeeper opens it without complaint on any Mac running macOS 14 or newer.

Hangar puts a glyph in your menubar and nothing in your Dock. On first launch it
runs a **setup check** that reads your machine and tells you exactly what works and
what does not, with a fix button beside anything actionable:

```
✓ 3 AWS profiles found          default, work, sandbox
✓ Credentials resolved          SSO profile default
✓ 249 hosts indexed             6 products, 5 environments
! SSH aliases not active yet    Add Include ~/.ssh/config.d/hangar   [Add Include Line]
✓ iTerm2 found                  Sessions open in iTerm2
✓ Shortcut ready                Press ⌘⇧H from any app
```

Nothing to configure before it works. If a check fails it says why and what to run.
You can reopen it any time from **Settings… → Setup Check**.

Two options are offered there rather than assumed: **Write SSH config aliases** and
**Open Hangar at login**. The login item is registered with `SMAppService`, so it
appears in System Settings under General, Login Items, where you can revoke it
independently of Hangar.

Closing the setup window leaves Hangar running in the menu bar; it says so rather
than just vanishing. If your menu bar has an overflow manager such as Ice or
Bartender, you may need to unhide the icon there once.

**Help** in the menubar lists every shortcut and the intended flow, so the app
explains itself without this README.

### Updates

**Settings… → Check for Updates**. Hangar reads the GitHub releases API only when
you ask, or once at launch if you set `check_updates_on_launch`.

Two channels, switchable in **Settings… → Update Channel**: `stable` sees full
releases, `beta` also sees prereleases. An update is installed only if Apple
notarized it *and* it is signed by this project's Developer ID team, verified as a
cryptographic codesign requirement rather than by parsing text.

<details>
<summary>Building from source instead</summary>

```sh
git clone git@github.com:goriparthi/hangar.git
cd hangar
make run
```

`swift build` needs only **Command Line Tools**. Two steps need Xcode: `actool`,
which compiles the asset catalog, and XCTest; `make` finds Xcode.app for both and
says so if it is missing. There are **no Swift package dependencies**, no AWS SDK,
and no runtime dependency on the `aws` CLI.

| Target | What it does |
|---|---|
| `make run` | build, install to `~/Applications`, launch |
| `make test` | the offline test suite, no network needed |
| `make verify-assets` | proves every brand asset resolves in the built bundle |
| `make bundle` | assemble and sign `dist/Hangar.app` |
| `make dmg` | signed, notarized DMG. See [RELEASING.md](RELEASING.md) |

</details>

## First run

Hangar creates `~/.hangar/config.json` and indexes your fleet on launch. The setup
check offers the one optional step: adding this as the **first** line of
`~/.ssh/config`, which is what makes the aliases work outside Hangar.

```
Include ~/.ssh/config.d/hangar
```

The **Add Include Line** button does it and keeps a backup. It must sit above any
`Host *` block: ssh_config is first-match-wins per keyword, so a catch-all above it
would beat every generated entry. Hangar connects fine without it; only the
`ssh payments-prod-web-1` shorthand needs it.

## Discovery

Hangar calls `ec2:DescribeInstances` once and caches the result locally. Hosts are
grouped and named from four tags:

| Tag | Used for |
|---|---|
| `product` | top-level grouping |
| `env` | environment grouping and the production treatment |
| `env_name` | disambiguating parallel environments |
| `Name` | the host's role |

Each host gets three ssh names: a readable alias, a stable instance-id alias, and
its real hostname.

```
Host payments-prod-web-1 payments-prod-web-i-0a1b2c3d web.prod.payments.internal.example.com
  HostName web.prod.payments.internal.example.com
  User deploy-user
  UserKnownHostsFile ~/.ssh/known_hosts.ec2
  StrictHostKeyChecking accept-new
```

Ordinals appear only where aliases collide, oldest instance first. The id-based
alias is built from the unnumbered stem, so it survives an autoscaling group
reshuffling the ordinals.

The generated file is rewritten wholesale on every sync, so terminated instances
drop out on their own and there is no merge logic to get wrong in a file that can
lock you out of every host you have.

## Credentials

Resolved the way the AWS CLI resolves them, reading only files already in your
home directory:

1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from the environment
2. static keys in `~/.aws/credentials`
3. SSO, via `~/.aws/config` and the token cache in `~/.aws/sso/cache`
4. `role_arn` with `source_profile`, assumed through STS
5. `credential_process`

Expired SSO tokens are refreshed in place using the cached refresh token, so you
are not sent back to `aws sso login` until the refresh token itself lapses.

## Security

- **Nothing is uploaded.** There is no Hangar server, account, or telemetry.
- **No private keys are read.** Hangar reads `~/.aws/config`,
  `~/.aws/credentials`, the SSO token cache, and EC2 instance tags. Key material
  stays with `ssh` and your agent.
- **One AWS call to list the fleet**, `ec2:DescribeInstances`, signed with SigV4.
  Depending on the profile it is preceded by an STS `AssumeRole` or an SSO token
  exchange, and nothing else.
- **Read-only against AWS.** Hangar never mutates infrastructure.
- **It owns one file**, `~/.ssh/config.d/hangar`, written atomically at `0600`
  after `ssh` itself validates the syntax. Your own `~/.ssh/config` is touched
  only by the explicit menu action, which keeps a backup.
- **Tags are untrusted input.** Anyone who can tag the account can influence what
  Hangar writes, so values are quoted on the way into `ssh_config` and
  shell-quoted on the way into a terminal. A value carrying a line break is
  dropped and the host reported as skipped.
- **`credential_process` runs through `/bin/sh`** when a profile configures one,
  exactly as the AWS CLI does. That command is yours, from your `~/.aws/config`.

Full detail, and how to report a hole, in [SECURITY.md](SECURITY.md).

## Configuration

`~/.hangar/config.json`:

```json
{
  "profile": null,
  "region": null,
  "terminal": "iterm",
  "ssh": {
    "user": "your-login",
    "identity_file": null,
    "known_hosts_file": "~/.ssh/known_hosts.ec2",
    "strict_host_key_checking": "accept-new"
  },
  "overrides": [
    { "match": { "product": "payments", "env": "prod" },
      "user": "rocky", "identity_file": "~/payments_prod.pem" }
  ],
  "hotkeys": [
    { "keys": "cmd+shift+h", "title": "All hosts", "filter": {} },
    { "keys": "cmd+shift+p", "title": "Prod", "filter": { "env": "prod" } }
  ],
  "refresh_minutes": 30,
  "healthy_within_hours": 24,
  "sync_ssh_config_on_refresh": true,
  "update_channel": "stable",
  "check_updates_on_launch": false,
  "launch_at_login": false
}
```

`identity_file: null` means Hangar says nothing about keys and lets `ssh` and your
agent behave as they already do. Set it to pin one, and `IdentitiesOnly yes` is
added alongside so a loaded agent cannot cause `Too many authentication failures`.

Each hotkey gets its own registration and its own filter, so
<kbd>⌘</kbd><kbd>⇧</kbd><kbd>P</kbd> can open straight into production. Hotkeys
use `RegisterEventHotKey`, which needs **no Accessibility permission**.

### Fixing a host whose login is wrong

<kbd>⌘</kbd>-click a host in the panel or the menubar, or press <kbd>⌘</kbd><kbd>E</kbd>.

**Detect Login** probes the usual cloud-image logins in parallel and keeps the
first that authenticates. **Test** checks whatever is in the fields.
**Applies to** decides the blast radius: this host only, every host of that role
in that environment, or the whole product.

Edits are saved as overrides in `~/.hangar/config.json` and the ssh include is
regenerated. They are never written straight into `~/.ssh/config.d/hangar`,
because that file is regenerated on every refresh and a direct edit would not
survive it.

## Keyboard

| Key | Action |
|---|---|
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>H</kbd> | open the panel from anywhere |
| <kbd>Return</kbd> | connect in your terminal |
| <kbd>⌘</kbd><kbd>Return</kbd> | copy the ssh command |
| <kbd>⌘</kbd><kbd>E</kbd> | edit this host's ssh user or key |
| <kbd>⌘</kbd><kbd>R</kbd> | refresh the fleet |
| <kbd>↑</kbd> <kbd>↓</kbd> | move selection |
| <kbd>⌘</kbd>-click | edit a host's ssh user or key |
| <kbd>esc</kbd> / <kbd>⌘</kbd><kbd>Q</kbd> | close the panel, leaving Hangar running |

## Architecture

```
app/
  Resources/      asset catalog, layered app-icon sources, Info.plist
  Sources/
    HangarCore/   AWS config, SigV4, SSO, EC2, ssh config writer, fuzzy, truncation
    Hangar/       brand tokens, hotkeys, panel, rows, menubar, editor, launcher
  Tests/          the offline test suite
design/           brand kit and its source assets
site/             the landing page published to GitHub Pages
intent/           one directory per change: intent, spec, plan
evals/            product promises, checked in CI
scripts/          build, test, and release
```

`HangarCore` is UI-free, which is what makes it testable. Search is byte-level
subsequence matching over a precomputed index: fifteen keystrokes across 249 hosts
costs under 7 ms.

## Status

Early but in daily use. The layered app icon is a
[remaining manual step](ICON_COMPOSER_MANUAL_STEP.md); the bundle currently ships
a flattened icon.

Releases are signed and notarized. See [RELEASING.md](RELEASING.md) for how a DMG
is cut and what the updater will refuse to install, and
[CONTRIBUTING.md](CONTRIBUTING.md) if you want to change something.

## How it is built

Hangar is written by a person working with an agent, and the repository is laid
out so that arrangement produces something trustworthy rather than something that
merely compiles. The working method, the review passes, and an honest account of
what it has caught are in
[docs/ai-native-sdlc.md](docs/ai-native-sdlc.md).

## License

[MIT](LICENSE)
