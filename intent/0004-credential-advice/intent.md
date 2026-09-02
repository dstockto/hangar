# 0004: advice that was right once and wrong the rest of the time

## How this came about

A screenshot of the menubar, mid-failure, with the question:

> what if someone is using old school ~/.aws/credentials style? wouldn't that
> error be invalid? does this need to be tweaked? or is that already handled and
> it is only showing because we used sso in the past?

The screenshot showed "Credentials expired. Run aws sso login, then retry." The
answer to the last part is yes: it looked correct because that machine does use
SSO. The answer to the first part is that the message was hardcoded.

## What was actually there

```swift
if lowered.contains("expired") || lowered.contains("sso session") { … }
    return "Credentials expired. Run aws sso login, then retry."
```

Any error whose text contained "expired", whatever the source, produced SSO
advice and a **Copy Login Command** button that copied a command the user had no
use for. Someone with a key pair in `~/.aws/credentials` is told to run a thing
that cannot help them, next to a button that helpfully copies it.

The same string matching drove the setup check's remedy.

## Why it was structured that way

Because "expired" is in the error text, and the error text was the only thing in
hand at the point of failure. The profile had already been consumed by the time
the message was built. Fixing it meant reading the profile's *shape* before
resolution is attempted, so that when resolution fails there is still something
to reason from.

That is the actual lesson: recovery advice is a function of the mechanism, not of
the error string. The error string tells you *that* it failed.

## The decisions

- Advice comes from the profile that was attempted: SSO, static keys, static keys
  with a session token, an assumed role, `credential_process`, or environment
  variables. Each gets its own sentence naming what to look at.
- A command is offered **only** when a command would help. For static keys there
  is nothing to run, so no button appears rather than a button that lies.
- An SSO-specific error type is trusted whatever the profile looks like, since it
  can only come from that path.
- An error that is not about credentials passes through untouched. A 503 is a 503,
  and dressing it up as a credential problem sends the user somewhere useless.

## Proof

`CredentialAdviceTests`, one case per mechanism, and the one that matters most is
the regression: a static-keys profile receiving an expired-token error is never
told to run `aws sso login` and is never offered a command to copy.
