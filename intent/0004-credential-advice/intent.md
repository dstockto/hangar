# Intent: tell the user the truth about why credentials failed

## Problem

When a refresh fails, Hangar said "Credentials expired. Run aws sso login, then
retry." for any error whose text contained "expired", regardless of how the user
authenticates. For an SSO profile that is correct. For a key pair in
`~/.aws/credentials` it sends the user to a command that cannot help them, and
offers a "Copy Login Command" button that copies nonsense.

Found by looking at the menu and asking what an old-school
`~/.aws/credentials` user would see.

## Outcome

The recovery Hangar suggests matches how the user actually authenticates, and it
offers a command only when a command would help.

## Constraints

- Errors that are not about credentials pass through unchanged. A 503 is a 503.
- The profile may fail to resolve before its type is known, so the type has to be
  read separately.

## Out of scope

Fixing the credentials for the user.
