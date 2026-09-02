# Intent: make the repository safe to publish

## Problem

Hangar was written as a private tool and is about to be public. Code that is fine
for one trusted operator is not automatically fine for strangers running it
against their own AWS accounts, and a public repository invites reading the code
for holes rather than using it.

## Outcome

A repository that can be read by a hostile stranger and run by a trusting one,
with no defect that a careful reviewer would find embarrassing.

## Affected

- Anyone who downloads a release and points it at their own account.
- The author, whose AWS-adjacent code is now a public artifact.

## Constraints

- No new dependencies.
- No behaviour change for the existing user beyond fixing what is broken.
- Anything the documentation claims must be true.

## Open questions, resolved during the work

- *Does the legacy `bin/hangar` shell CLI ship?* No. It documented a `--sync` flag
  it never implemented and pointed at config paths the app does not use.
- *Is the in-place updater real?* It was dead code. Wired under 0005.

## Out of scope

Feature work, visual design, the landing page.
