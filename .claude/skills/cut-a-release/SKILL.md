---
name: cut-a-release
description: Cut a signed, notarized Hangar DMG and publish it. Use when asked to cut a release, bump the version, build a DMG, or publish to GitHub releases.
---

# Cutting a release

Read `RELEASING.md` for the mechanics. This is the order, the checks, and the
parts a person has to approve.

## Order

1. `make test` green. Not negotiable; the release build is the same code.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `app/Resources/Info.plist`. Semver on the short string. A user-visible
   behaviour change is a minor bump, not a patch.
3. `make dmg`. Builds, signs with Developer ID and the hardened runtime,
   notarizes the app, staples it, builds the DMG, signs it, notarizes that,
   staples it, and prints the sha256.
4. Verify the artifact before it goes anywhere, by mounting it and checking the
   app inside against the two gates the in-app updater applies:

   ```sh
   spctl -a -vv -t exec /Volumes/.../Hangar.app
   codesign --verify --deep --strict \
     -R='anchor apple generic and certificate leaf[subject.OU] = "QX3NQYWX6F"' \
     /Volumes/.../Hangar.app
   xcrun stapler validate /Volumes/.../Hangar.app
   ```

   If either gate fails, an existing install will refuse the update. Stop.
5. Publish, then confirm by downloading the published asset back and comparing
   its sha256 to the one `make dmg` printed.

## What needs a person

- Notarization submits the binary to Apple. Deliberate, never incidental.
- Publishing a release is public and the in-app updater picks it up within a day.
- **Deleting** a published release breaks the updater for anyone already on it.
- Rewriting published history. The gate in `.claude/hooks/production-gate.sh`
  blocks all of these; that is the gate working, not a problem to route around.

## After publishing

- The release notes state what changed and why, with the sha256 and the two
  commands a suspicious user can run to verify the download themselves.
- Confirm the unauthenticated releases API returns the new tag, because that is
  the exact call the in-app updater makes:

  ```sh
  curl -sS -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/goriparthi/hangar/releases/latest
  ```

## Things that have gone wrong here

- Stapling only the DMG. Gatekeeper then accepts the app while the image is
  mounted and falls back to asking Apple online once it is dragged out, so a
  first launch on an offline machine fails. Staple both.
- A version bump committed without the DMG being rebuilt, so the published
  artifact and the tag disagreed.
