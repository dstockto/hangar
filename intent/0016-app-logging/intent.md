# 0016: a log worth reading

## How this came about

> also, we should have app logging, so we can read logs on errors and what not
> for a good loop validation on running app

Two days of building this app have been spent inferring state from screenshots.
When the setup window sat blank, the only way to find out that a
`credential_process` was hanging was to reason about it from the source. When an
uninstall left a copy behind, the answer came from `ls` and file timestamps,
because the app said nothing about what it had removed.

That is the case for logging here. Not "production observability" in the abstract:
an agent driving the running app needs a text stream it can read, and a user
reporting a bug needs something to attach that is not a screenshot.

## The decision

Both sinks, because they answer different questions.

- **`os.Logger`**, the unified log, for everything. It is free, structured,
  survives a crash, and shows up in Console.app with no work from us.
- **A file**, `~/.hangar/logs/hangar.log`, rotating, `0600` inside `0700`,
  because `log show` needs the CLI and a predicate, retention is short and not
  ours to control, and a loop that wants to know what just happened should be
  able to `tail` a path.

## What goes in it, and what does not

Fleet data is redacted in both sinks: instance ids and hostnames are replaced by
a short stable digest, so two lines about the same host can be tied together
without the file naming anyone's infrastructure. Counts, regions, profile names,
timings, decisions and every error stay in full.

The test of the rule: the log file should be safe to paste into a public issue
without reading it line by line first. A log nobody dares attach is a log that
does not exist.

Credentials never appear, in any form, at any level. That is not a redaction
rule, it is that they are never passed to the logger.

## Out of scope

- Sending anything anywhere. The landing page says nothing leaves the machine,
  and a log is exactly the thing that quietly breaks that promise elsewhere.
- A log viewer in the app. A menu item that reveals the file in Finder is enough.
- Debug-level output in the file. The unified log carries it; the file is events
  and errors.
