# Intent: check for updates and install them

## Problem

Two problems, one of which was invisible.

Visible: Hangar only checked for updates when asked, and then opened a browser
page. A menubar utility that is running anyway should notice a release itself.

Invisible: `Updates.stage`, the download-verify-stage-swap path, was never called
by anything. It was complete, careful, and dead, while `README.md`, `SECURITY.md`
and `RELEASING.md` all described how the in-place installer verified downloads.
The documentation described a code path that could not run.

## Outcome

Hangar checks daily by default and offers to install in place, using the verified
path that already existed.

## Constraints

- Nothing unprompted may spend the user's bandwidth without asking.
- Nothing may replace the running app without an explicit confirmation.
- The check must be daily in wall-clock terms, not once per launch. A laptop that
  sleeps and wakes all day must not check twenty times.
- The privacy claim changes: the README said Hangar makes no network request the
  user did not ask for. That sentence has to change with the default.

## Out of scope

Delta updates, background download, release-note rendering in-app.
