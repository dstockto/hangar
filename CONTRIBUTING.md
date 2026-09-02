# Contributing

## Build and test

```sh
make test     # offline suite, no network and no AWS account
make run      # build, install to ~/Applications, launch
```

`swift build` needs only the Command Line Tools. Two steps need Xcode: `actool`,
which compiles the asset catalog, and XCTest. `make test` points `DEVELOPER_DIR`
at Xcode for the run rather than making you `xcode-select` back and forth.

There are no Swift package dependencies, and there is no runtime dependency on the
`aws` CLI. Please keep it that way.

The package builds in **Swift 6 language mode** with complete concurrency checking,
warning-free. A change that needs `@unchecked Sendable` or `nonisolated(unsafe)` to
compile is a change that needs rethinking first.

## Layout

```
app/Sources/HangarCore/   AWS config, SigV4, SSO, EC2, ssh config writer, fuzzy search
app/Sources/Hangar/       AppKit: menubar, panel, rows, editor, launcher, updater
app/Tests/                the offline suite
scripts/                  build, test, and release
design/                   brand kit and its source assets
site/                     the landing page, published by .github/workflows/pages.yml
```

Logic belongs in `HangarCore`, which is UI-free and therefore testable. If
something in the AppKit layer is worth a test, move it down first; that is how
`SSHCommand` ended up in the core.

`hangar-probe` is a development target, not part of the app. It walks the real
credential chain against your own account and prints what it found, which is the
quickest way to see why a profile does not resolve:

```sh
swift run --package-path app hangar-probe            # the default profile
swift run --package-path app hangar-probe env prod   # tag key/value pairs filter
```

It uses whichever profile the AWS CLI would, and it reaches AWS, so it is the one
thing here that is not offline.

## The workflow

Changes that a user could notice, or that touch credentials, `ssh_config` or the
updater, start with an `intent.md` in `intent/<n>-<slug>/`. The reasoning is in
[docs/ai-native-sdlc.md](docs/ai-native-sdlc.md); the short version is that a
paragraph is cheap to disagree with and a merged branch is not.

Every change is held to the passes in [REVIEW.md](REVIEW.md), and `evals/check.sh`
must stay green: those cases are the product's promises, and each one is there
because it was once broken.

## What a change needs

- A test, if it is a behavior change. `make test` must be green.
- Values from EC2 tags or `~/.hangar/config.json` are untrusted. Anything written
  into `ssh_config`, or into a command handed to a terminal, goes through
  `SSHConfigValue` or `Shell` first. See [SECURITY.md](SECURITY.md).
- No em dashes in UI copy, comments, or commit messages.
- Comments say why, not what, and stay short.

## Commits

One-line summary, then at most a few lines of body when they add something. No
Claude or other tool co-author trailers.

Before pushing, check the diff for anything that should not be public: account
ids, real hostnames, internal IPs, key material.
