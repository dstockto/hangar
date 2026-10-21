# 0035: a refresh you can ask for

## How this came about

The question was simple: does the command line offer a way to refresh the fleet?
It did not. `hangar` reads `~/.hangar/cache` and nothing else, and when that cache
went stale the best it could do was say so on stderr and tell you to go open the
app. Someone who lives in a terminal, or an agent driving `hangar`, had no way to
get a fresh fleet without leaving the shell and clicking a menu.

There were two ways to fix it. The command line could fetch the fleet itself,
since everything it needs is already in `HangarCore`. Or it could ask the running
app to fetch and wait for the answer. The first breaks the promise the command
line has made since 0.5.0: no credential, no network, no AWS call, fast enough to
put behind a keystroke. The second keeps it. This change takes the second.

## What was decided

**`hangar refresh` is a verb.** It is the first plain word on the line, the same
as `ssh`, `tags` and `values`, so `hangar -s refresh` and `hangar -- refresh` still
find a host with that name. It takes no query, and it refuses `-f`, `-n`, `-1`,
`--dry-run`, `--cache` and `--exec` instead of ignoring them, for the reason
`tags` already refuses `-f`. Someone who typed a narrowing flag believes they
asked a narrower question than they did. `--timeout` is the one flag it takes,
and it means how long to wait. The default is 120 seconds.

**The request is a distributed notification.** The command line posts
`com.goriparthi.hangar.refresh.request` with a fresh UUID as the object. The app
answers on `com.goriparthi.hangar.refresh.reply` with the same UUID, first
`started` and then either `finished` or `failed`. Both sides post with
`deliverImmediately`, because a menubar app is almost never the active app and a
suspended observer would otherwise hold the request until someone clicked on it.
No URL scheme, no socket and no file to poll. Nothing new is written to disk.

**Silence means the app is not running.** The app answers `started` before it
starts work, so three seconds of nothing is enough to say so. That exits `5`. A
refresh that fails, or that does not finish within the timeout, exits `6`.
Neither of those codes was in use.

**The app runs the refresh it already has.** `RefreshListener` calls
`FleetStore.refresh()`, the same one the menu's Refresh item and the timer call.
The menubar icon pulses the same way and the ssh config is rewritten the same
way. If a refresh is already running, the request waits for that one. If one
finished in the last ten seconds and did not fail, the request gets that result
without fetching again. Either way, requests start at most one fetch every ten
seconds, and every request waiting at once is answered from the same refresh. An
agent that runs `hangar refresh && hangar ssh ...` once per host should cost one
fetch.

**A partial failure says so.** A refresh where EC2 is denied and `~/.ssh/config`
still works succeeds, and the fleet shrinks to the local hosts. Reporting "done"
there would look like the EC2 hosts were terminated. Each source that reported a
problem is printed as its own line on stderr before the host count.

**The host count comes from the cache file.** The reply does not carry a number.
The command line reads `~/.hangar/cache` once the app says it finished, which is
the same file every other `hangar` command reads, so the number it prints is the
number the next `hangar` will see.

## Untrusted input

Any process in the login session can post the request or a reply.

- The app only echoes a request id that parses as a UUID of the expected
  length. Anything else is dropped.
- A request can only start the refresh the menu already offers, and requests
  start at most one fetch every ten seconds, including after a failure. The
  first draft only spaced them after a success, so a loop against an expired
  session would have resolved credentials back to back, and a
  `credential_process` that prompts would have prompted each time. At most 64
  requests wait at once, and they share one task.
- Reply text is printed on the user's terminal, so it goes through
  `FleetOutput.display` line by line and is capped at 2000 Unicode scalars. A
  cap counted in characters let combining marks through at any size. C0 and C1
  control characters are replaced, and a carriage return ends a line instead of
  returning over it. C1 is new to `display` with this change: U+009B is a CSI in
  one scalar, and tag output had the same gap.
- The failure detail in a reply is readable by other processes in the session.
  It holds no secret, but it can carry the account id, a role ARN, a profile
  name and the SSO start URL. An unsandboxed process running as the user can
  already read all of that from `~/.aws`. Whether a sandboxed observer receives
  the reply's userInfo has not been checked.
- A forged `finished` could make the command line report success for a refresh
  that never ran. The count it prints still comes from the cache file, which is
  `0600`, so a forged reply cannot change what it reports about the fleet.

## Not taken

- **Fetching from the command line.** Covered above. The eval
  `product-command-line-never-calls-aws` pins it, because this change made it
  tempting.
- **Launching the app when it is not running.** Starting a GUI app from a shell
  command, possibly over ssh or from an agent, is a bigger step than the person
  asked for. The message tells them to open it.
- **A `--refresh` flag on listing.** `hangar refresh && hangar ...` already says
  it, and a flag would need its own answer for what a failed refresh does to the
  listing after it.
- **Fixing an early `.failed` in `FleetStore.refresh`.** When the config does not
  parse, the refresh function sets the status to failed and keeps going. A
  request that arrives in that window reports the failure before the refresh
  lands, and the guard against a second concurrent refresh no longer holds. The
  menu's Refresh item has the same problem, so it wants its own change.

## Testing

`RefreshSignalTests` and `RefreshWaitTests` cover the id check, every reply
round trip, C0 and C1 controls and overlong text, when a request may fetch, and the
waiting rules: no answer, answered and timed out, a result with no `started`, and
two app copies answering. `HangarCommandTests` covers the verb and each refused
flag.

The offline suite cannot post a distributed notification, since doing so would
reach a real Hangar running on the same machine. The cross-process path was
checked by hand against a stand-in responder. That covered success with a source
note, failure carrying ESC, a timeout, and no responder at all. The last one
waited three seconds at no CPU cost and exited `5`.
