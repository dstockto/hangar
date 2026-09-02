# Plan: automatic updates

1. `HangarCore/UpdateSchedule.swift`, new, so the schedule is testable. `Updates`
   in the AppKit target delegates to it.
2. `HangarConfig`: `update_check_hours`, and `check_updates_on_launch` flips to
   true by default.
3. `HangarApp`: an hourly timer that calls `checkIfDue`, an `availableUpdate`
   the menu can read, and `installUpdate(confirmFirst:)`.
4. `MenuBarController`: the install item and the two new callbacks.
5. `SetupWindow`: the daily toggle and the channel picker.
6. Documentation: `README.md` and `SECURITY.md`, because the default changed.

## Tests

`UpdateScheduleTests`: off at zero, due when never run, not due inside the
window, due outside it, the stamp round-trips through a file, a missing stamp is
not an error. The existing `ConfigCodingTests.testDefaults` had asserted the old
default and is updated deliberately, not deleted.

The install path itself is verified by hand, recorded here: re-sign a copy of the
bundle ad hoc, confirm `spctl` and the codesign requirement both reject it.
