# Hangar

A native macOS menubar launcher that turns changing EC2 instances into stable,
searchable SSH targets. Swift 6, AppKit, no package dependencies.

This file is the institutional knowledge for the repo: conventions, commands,
architecture, and the mistakes that have actually bitten. Read it before changing
anything. The workflow it belongs to is described in
[docs/ai-native-sdlc.md](docs/ai-native-sdlc.md).

## Commands

```sh
make test            # the offline suite. Must be green before any commit.
make bundle          # assemble and sign dist/Hangar.app
make verify-assets   # prove every brand asset resolves in the built bundle
make run             # build, install to ~/Applications, launch
make dmg             # signed, notarized DMG. See RELEASING.md
```

`swift build` needs only the Command Line Tools. Two steps need Xcode: `actool`
for the asset catalog, and XCTest. `make test` points `DEVELOPER_DIR` at Xcode for
the run and uses its own scratch path, because two toolchains sharing one `.build`
leave modules the other cannot read.

## Architecture

```
app/Sources/HangarCore/   UI-free: AWS config, SigV4, SSO, EC2, ssh config writer,
                          tag mapping, fuzzy search, truncation, sanitizing
app/Sources/Hangar/       AppKit: menubar, panel, rows, editor, updater, brand
app/Tests/                the offline suite
site/                     the landing page, deployed by .github/workflows/pages.yml
design/                   brand kit, wordmark, and their source assets
intent/                   one directory per change: intent, spec, plan
evals/                    behavioural checks the agent workflow is gated on
```

**Logic belongs in `HangarCore`.** It is UI-free and therefore testable. If
something in the AppKit layer is worth a test, move it down first. That is how
`SSHCommand` and `UpdateSchedule` ended up in the core.

## Conventions

- **Swift 6 language mode, warning-free.** A change that needs `@unchecked
  Sendable` or `nonisolated(unsafe)` to compile needs rethinking instead.
- **No package dependencies, no AWS SDK, no runtime dependency on the `aws` CLI.**
  This is a product property, not an accident. Keep it.
- **Comments say why, not what, and stay to two lines.** The code shows the what.
- **No em dashes** anywhere: UI copy, comments, commit messages, docs.
- Commit messages: one imperative line, then at most three or four lines of body
  when the why is not obvious. No Claude co-author trailers. No ticket prefixes;
  this repo has no Jira.
- **Commits are dated outside business hours.** Every commit here is stamped
  Monday to Friday before 08:00 or after 18:00 local time, and never on a
  Saturday or Sunday. This is a personal project, and its history says so. When
  committing inside those hours, set both dates explicitly:

  ```sh
  GIT_AUTHOR_DATE="2026-09-02T07:15:00" \
  GIT_COMMITTER_DATE="2026-09-02T07:15:00" \
  git commit -m "..."
  ```

  Both variables, not just the author date: the committer date is what `git log
  --date` and GitHub show by default.

## Untrusted input

EC2 tags are written by anyone who can tag the account, and `~/.hangar/config.json`
is hand-edited. Neither is trusted just because it arrived over TLS.

- Anything written into `ssh_config` goes through `SSHConfigValue`: quoted when it
  contains whitespace, refused outright when it contains a newline, CR, NUL or a
  double quote. A newline would let a tag append its own directive, and
  `ProxyCommand` is a directive ssh executes.
- Anything used as a *name* on a `Host` line is held to `isSafeAlias`, which is
  stricter still, because that line is a pattern list rather than a value.
- Anything reaching an `ssh` argument vector followed by another argument needs
  `--` before it. Use `SSHProbe` rather than building the vector by hand.
- Anything written under `~/.hangar` goes through `PrivateFile`, which creates at
  0600 rather than tightening afterwards.
- Anything interpolated into a command handed to a terminal goes through `Shell`.
- Region names go through `AWSRegion` before reaching an endpoint hostname.
- A host that cannot be represented is skipped and **reported**, never silently
  dropped. Silence looks like the instance was terminated.

## Mistakes this repo has already made

Kept because each one cost real debugging and would be easy to reintroduce.

1. **One bad tag took out every alias.** EC2 allows spaces in tag values. An
   unquoted `HostName web 1` made ssh reject the whole generated file, so a single
   sloppy tag cost the user all 249 aliases. Quote, and validate per entry.
2. **Hardcoded advice for a failure that has several causes.** "Run aws sso login"
   was shown for any error containing "expired", which is useless to someone with
   a key pair in `~/.aws/credentials`. Recovery advice must come from the profile
   that was actually tried, via `CredentialAdvice`.
3. **Hardcoded tag names.** `product`/`env`/`env_name`/`Name` were assumed, so the
   app was useless to a fleet tagged `Service`/`Environment`/`Component`. Tag keys
   are a mapping with candidates, not constants.
4. **A force-unwrapped interpolated URL.** `URL(string: "https://ec2.\(region)…")!`
   traps on a region containing a space, which is a plausible typo in a
   hand-edited config. Validate, then throw a readable error.
5. **Dead code the documentation described as shipping.** The verified in-place
   updater existed and was never called, while the README explained how it
   worked. If the docs claim it, wire it or delete it.
6. **`rm -rf` before the replacement succeeded.** The update helper deleted the
   installed app and then moved the new one in. Move aside, swap, then clean up.
7. **A shared build directory across two toolchains.** See Commands above.
8. **`text-transform: uppercase` on a product name.** It rendered "MACOS".
   Capitalisation can be part of a name.
9. **An argument vector is not enough for `ssh`.** A hostname tag of
   `-oProxyCommand=…` followed by a trailing argument is parsed as an option and
   the command runs. `--` before the host is the only fix. See `SSHProbe`.
10. **The `Host` line is a pattern list, not a value.** A tag of `*` produced a
    catch-all that ssh accepted and that outranked the user's whole
    `~/.ssh/config`, silently, because `ssh -G` validates it happily. Names on
    that line go through `SSHConfigValue.isSafeAlias`, which is stricter than
    `isEmittable`.
11. **`replaceItemAt` keeps the destination's file mode.** A pre-existing 0644
    ssh include stayed 0644 no matter how tight the temporary file was. Chmod
    after the replace, not only before.
12. **`createDirectory(attributes:)` does not tighten an existing directory.** A
    hand-made `mkdir ~/.hangar` stayed at the umask. `PrivateFile.ensureDirectory`
    sets the mode either way.
13. **A label that assumed the default config.** `leafLabel` cut `product-env`
    off every alias, so a fleet grouped by product alone showed `web-1` three
    times for prod, stage and qa. Anything that trims a label has to be told the
    levels the menu was actually built from.
14. **A screen with no way off it.** Opening a host put its record on the
    Insights tab, and the only control that stepped back out was the hub in the
    middle of the cluster, which is on the other tab. Every view that can be
    navigated into carries its own way out, on itself.
15. **`NSStackView.fittingSize` leaves the stack's own `edgeInsets` out** of the
    cross-axis width. Sizing a panel from it produced a notice card exactly as
    wide as its text column, so 30 points of padding a side became none and the
    body printed against the rounded edge. Size from the content plus the
    padding, both as numbers.
16. **An external process with no deadline.** `credential_process` is the user's
    own command, and `readDataToEndOfFile` waits for the pipe to close, which a
    helper that hangs never does. The fleet refreshed forever and the setup
    window sat blank. Every process Hangar runs gets a deadline and a kill.

## Permissions and file modes

Everything Hangar writes under `~/.hangar` and `~/.ssh/config.d` is `0600` inside
`0700` directories, including the fleet cache and the update timestamp. The cache
is the whole inventory: instance ids, private addresses, every tag.

## Before you commit

1. `make test` green.
2. Read the staged diff for anything that should not be public: account ids, real
   hostnames, internal IPs, key material. Test fixtures use `example.com`,
   `123456789012` and `10.0.0.1` deliberately.
3. Check [REVIEW.md](REVIEW.md) for the passes that apply to what you touched.
