# 0016 spec: app logging

## Shape

```swift
Log.info(.fleet, "refresh finished", ["hosts": "223", "region": "us-west-2", "ms": "412"])
Log.error(.credentials, "credential_process timed out", ["profile": "work", "seconds": "30"])
```

- `Category`: `app`, `fleet`, `credentials`, `ssh`, `updates`, `uninstall`.
  One per area that can fail on its own.
- Levels: `debug`, `info`, `warning`, `error`. `debug` goes to the unified log
  only; the file starts at `info`.
- Fields are `[String: String]`, rendered `key=value` sorted by key, so a line
  is greppable and diffable. A value containing a space is quoted.

## The line

```
2026-09-02T13:41:09Z  INFO   fleet        refresh finished  hosts=223 ms=412 region=us-west-2
```

UTC, always, per the house rule on timestamps. Level and category are padded so
the message column lines up when a human reads a screenful.

## Redaction

`Redact.host(_:)` and `Redact.instance(_:)` turn `web-1.prod.payments.example.com`
and `i-0a1b2c3d4e5f6a7b8` into `host#4f2a` and `i#8c31`: a four-character digest
of the value, stable within a run and across runs on the same machine, and not
reversible without the original. Callers redact at the call site, because a
logger that tries to guess which of its fields are sensitive will guess wrong.

Because redaction happens at the call site, nothing sensitive reaches either
sink, so the unified log line is marked `privacy: .public`: hiding a string that
is already a digest would only blind the person debugging their own machine.

A note from building this: `log show` returns nothing at all on the development
machine, for any subsystem, system-wide. Unified logging is not always readable,
which is the argument for the file rather than an argument against `os.Logger`.
Both sinks stay; only one of them can be relied on.

## The file

- `~/.hangar/logs/hangar.log`, created through `PrivateFile` so it is `0600` from
  creation inside a `0700` directory, like everything else Hangar writes.
- Rotation at 512 KB to `hangar.log.1`, one generation kept, so the log costs at
  most about a megabyte and never needs pruning by hand.
- Writes go through an `actor`, which is how a Swift 6 module gets a serialized
  writer without an `@unchecked Sendable` waiver. Callers do not await; the
  logging call returns immediately and the write lands in order behind the actor.
- A write that fails is dropped silently. A logger that throws, or that blocks the
  UI to complain about its own disk, is worse than a missing line.

## Where it is called

Enough to reconstruct a session without a debugger, and no more:

| Area | Logged |
|---|---|
| `app` | launch with version and install classification, hotkey registration outcome, quit |
| `fleet` | refresh start, finish with host count and elapsed ms, failure with the error |
| `credentials` | which source resolved, SSO refresh, `credential_process` timeout |
| `ssh` | aliases written with counts written and skipped, include line added or removed |
| `updates` | check outcome, staging, verification failures |
| `uninstall` | the list of bundles, each removal step, what could not be removed |

## Reaching it

**Settings → Configuration → Reveal Log in Finder**, next to the existing
`~/.hangar/config.json` row, and the path shown as a status row so it can be
read and typed without opening anything.

## Tests

- The rendered line: order of fields, quoting, UTC format, padding.
- Level filtering: `debug` never reaches the file.
- Rotation: crossing the threshold moves the file and starts a new one; only one
  generation survives.
- Permissions: the file is `0600` and the directory `0700`, from creation.
- The file sink is off under XCTest. The first run of this feature wrote the test
  suite's own lines into the developer's real log, which is both pollution and a
  test that depends on a home directory.
- `Redact`: stable for the same input, different for different inputs, and the
  original string never appears in the output.
