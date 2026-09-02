# Spec: automatic updates

## Schedule

`UpdateSchedule` keeps the last-check timestamp in
`~/.hangar/cache/last-update-check` at `0600`. `isDue(every:)` is false when the
interval is zero or negative, true when the file is missing, otherwise compares
elapsed wall-clock time. The timer ticks hourly and usually decides it is not due,
which is what makes the schedule survive sleep.

Config: `check_updates_on_launch` defaults true, `update_check_hours` defaults 24.

## Offering

Both paths end in an offer to install:

- **Asked for.** Straight to download, verify, stage, then a confirmation naming
  the version and stating that the download was verified.
- **Daily.** Ask first: "Download and Install", "Not Now", or "Release Notes".
  Only then download.

Nothing is said at all when there is nothing new and the user did not ask.

If the release has no DMG asset, the release page opens instead.

## Installing

Unchanged from what already existed and was never called: `spctl -a -t exec`, the
pinned team requirement against the mounted image and against the staged copy,
`ditto` for the copy, and a detached helper that waits for exit, moves the
installed app aside, swaps, relaunches, and restores on failure.

## Surface

The menu carries an "Install Hangar <version>…" item while an update is known.
Setup gains a "Check for updates daily" toggle beside the channel picker.

## Acceptance

The timestamp survives a restart and suppresses a second check inside the window.
The menu offers the install without a second check. The README no longer claims
Hangar makes no unrequested network request.
