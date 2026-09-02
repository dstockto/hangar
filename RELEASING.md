# Releasing Hangar

Signed, notarized DMG. A user downloads it, drags the app to Applications, and it
opens with no Gatekeeper warning and no `xattr` incantation.

## One-time setup

Already done on this machine; recorded so it can be repeated elsewhere.

**1. Developer ID Application certificate.** Required for distribution outside the
Mac App Store. `Apple Development` and `Apple Distribution` certs will not do.

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

**2. Notary credentials in the Keychain.** From an App Store Connect API key with
at least Developer access. Store it once; the secret then lives in the Keychain
and never in the repo, a dotfile, or an environment variable.

```sh
xcrun notarytool store-credentials "hangar-notary" \
  --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer <issuer-uuid>
```

Keep the `.p8` at `~/.appstoreconnect/private_keys/` with mode `600`. It is
gitignored, but it should never be near the repo in the first place.

## Cutting a release

```sh
make test                    # must be green
# bump CFBundleShortVersionString in app/Resources/Info.plist
make dmg                     # builds, signs, notarizes, staples, verifies
```

`make dmg` prints the sha256 and refuses to call itself published. What it does:

1. `swift build -c release`, then compiles the asset catalog with `actool`.
2. Assembles `dist/Hangar.app` and signs it with Developer ID, **hardened runtime**,
   a secure timestamp, and `app/Resources/Hangar.entitlements`.
3. Builds `dist/Hangar-<version>.dmg` with an `/Applications` symlink for drag and drop.
4. Signs the DMG, submits it to Apple's notary service, waits, and staples the ticket.
5. Verifies with `spctl`, which must report `source=Notarized Developer ID`.

Then attach the DMG to a GitHub release:

```sh
gh release create v0.2.0 dist/Hangar-0.2.0.dmg \
  --title "Hangar 0.2.0" --notes-file <notes>
```

Mark it as a prerelease for the beta channel:

```sh
gh release create v0.3.0-beta.1 dist/Hangar-0.3.0-beta.1.dmg --prerelease
```

## Update channels

The in-app updater reads the GitHub releases API.

| Channel | Endpoint | Sees |
|---|---|---|
| `stable` | `releases/latest` | full releases only |
| `beta` | `releases?per_page=20` | prereleases too, newest by version |

Set it in `~/.hangar/config.json` as `update_channel`, or from
**Settings… → Update Channel** in the menubar. Beta picks the newest by version
rather than by list order, so a stable hotfix correctly outranks an older beta.

Tags may be `v0.2.0` or `0.2.0`; the leading `v` is stripped. Prereleases sort
below their release, and numerically among themselves, so `0.4.0-beta.10` is newer
than `0.4.0-beta.2` and older than `0.4.0`.

## What the updater will and will not install

An update is only swapped in after **both** checks pass:

- `spctl -a -t exec` accepts it, meaning Apple notarized it.
- `codesign -R` verifies it against a pinned requirement,
  `certificate leaf[subject.OU] = "QX3NQYWX6F"`.

That second check is a cryptographic requirement, not a grep of codesign's output,
because that output contains the app's filename, which a hostile DMG author picks.
Both are run twice: once against the bundle on the mounted image, and again against
the staged copy that will actually be installed.

The swap runs in a detached helper that waits for Hangar to exit, replaces the
bundle, and relaunches. Nothing touches the installed app until the user quits, and
the installed bundle is moved aside rather than deleted, so a failed swap rolls
back instead of leaving no app at all.

## Verifying a DMG by hand

```sh
spctl -a -t open --context context:primary-signature -v dist/Hangar-0.2.0.dmg
codesign -dvvv dist/Hangar.app 2>&1 | grep -E 'Authority|TeamIdentifier|flags'
xcrun stapler validate dist/Hangar-0.2.0.dmg
```

`flags` must include `runtime`. Without the hardened runtime the notary service
rejects the submission, and the Apple events that open your terminal are killed.

## Bundle identity

Changing `CFBundleIdentifier` or the signing identity changes the app's TCC
identity, so macOS asks again for permission to control iTerm2 on first use. Do not
change either casually.
