# 0036: a terminal the command never had

## How this came about

`0027` shipped `--exec` with one thing left undone on purpose. Ctrl-C returned
the prompt and left the commands running, because Foundation starts each child in
its own process group and the terminal sends SIGINT to the foreground group, which
is `hangar`'s. The doc comment above `run` in `main.swift` and the README both say
so, and both say it wants its own intent. This is that intent.

The question was narrow: what does it take for Ctrl-C to stop what `--exec`
started? Checking that against a real terminal, rather than reading the comment,
turned up a second problem with the same cause, and it is the worse of the two.

## What was actually true

Both were reproduced under `script`, which gives `hangar` a real pty, against a
one-host fixture cache.

**Ctrl-C orphans the work.** `--exec sh -c 'sleep 40; echo done'`, then Ctrl-C
two seconds in. `hangar` exits, and the `sh` and the `sleep` keep running with a
parent of 1. `--timeout` does not help, because the loop that enforces it is the
process that just died.

**A child that touches the terminal is stopped, and `hangar` waits on it
forever.** The README says that at one host at a time "the command inherits your
terminal, so interactive things work". It inherits the file descriptor, but it
does not get the terminal. The child is in a background process group, and the
kernel stops a background process that reads from its controlling terminal
(SIGTTIN) or changes its settings (SIGTTOU). With `read x` as the command:

```
  PID  PGID TPGID STAT COMM
45065 45065 45065 SNs+ hangar-cli
45077 45077 45065 TN   sh
```

The terminal's foreground group is `hangar`'s, the child leads its own, and the
child is stopped. `stty -echo` is stopped the same way. Putting the terminal into
raw mode is the first thing ssh does for an interactive session, so `--exec ssh
-- {alias}` at the default `--parallel 1` should hang like this too. That has not
been checked against a real host. A stopped process still reports itself as
running, so the polling loop waits on it with no end. Ctrl-C does not get you out
either: it reaches `hangar`, which dies and leaves the stopped child behind.

Neither shows up from an agent or a script, because their stdin is not a terminal
and the kernel only stops a background process for using its *controlling*
terminal. That is likely why three review rounds on `0027` found neither.

A note on testing, because it misled the first attempt. A background job started
by a non-interactive shell begins with SIGINT ignored, and that survives `exec`.
The first Ctrl-C test showed `hangar` surviving the interrupt, which looked like a
finding and was the harness. The process under test has to have SIGINT reset to
the default first.

## Decided

**`hangar` stops what it started when it is told to stop.** For the length of an
`--exec` run, SIGINT, SIGQUIT, SIGTERM, SIGHUP and SIGPIPE are set to SIG_IGN, so
the default disposition does not kill `hangar` first, and a `DispatchSource` per
signal does the work outside signal-handler context. Each one sends SIGTERM to every live
group, escalates to SIGKILL after the same two seconds the deadline already uses,
starts no further hosts, and exits 128 plus the signal number, so `130` for
Ctrl-C. A killed host's output is still printed under its alias, so an
interrupted run keeps what it already learned. SIGHUP is on the list because
closing a terminal window signals the shell's jobs, and the children's groups
were never one of them. SIGPIPE is a reader that went away, as in `| head`,
which killed `hangar` the same way before this change.

- A signal that was already ignored when `hangar` started is left alone. A
  dispatch source fires for an ignored signal too, so the first cut made
  `nohup` protect nothing.
- A group that was told to end is followed after its leader exits. A member
  that ignores SIGTERM outlives the leader, and once the leader was reaped
  nothing would have sent the SIGKILL. The deadline had the same gap before
  this change.

Ignoring in `hangar` does not leak into the children. `Process` resets every
disposition and the signal mask when it spawns, which was checked rather than
assumed: a child of a `hangar` ignoring SIGINT reports the default handler.

**At one host at a time, the child also gets the terminal**, the way a shell
gives it to a job. It keeps its own process group, and `hangar` makes that group
the terminal's foreground group with `tcsetpgrp` before waiting, then takes it
back once the child exits. Ctrl-C, Ctrl-\ and terminal reads then reach the child
and everything it started, and not `hangar`. The `killpg` deadline from `0027`
still covers the whole tree, because the tree is still one group.

- The child can touch the terminal before `hangar` has handed it over. `hangar`
  sends SIGCONT to the group straight after the handover, which does nothing to a
  process that was never stopped.
- Taking the terminal back is done from a background group, which is itself a
  SIGTTOU. `hangar` ignores SIGTTOU around that call.
- A child that dies of SIGINT or SIGQUIT ends the run. The remaining hosts are
  not started and `hangar` exits `130` or `131`. Someone pressing Ctrl-C at host
  three of twenty wants to stop, not to move on to host four. A child that
  catches the signal and exits on its own terms, as an interactive ssh session
  does, is taken at its word.
- Ctrl-Z stops the child's group and not `hangar`, so the shell would never see
  a stopped job. `hangar` notices the stop by reading the process state, since
  `Process` reports a stopped process as running. It takes the terminal back,
  stops its own group so the shell reports the job, and on `fg` hands the
  terminal back and sends SIGCONT. The same path covers a run started with `&`
  whose command reaches for the terminal: the job stops, and `fg` lets it read.
- The terminal is opened as `/dev/tty` rather than taken from stdin, because ssh
  asks for a password on `/dev/tty` even when stdin is a pipe. It is only
  handed over while `hangar`'s own group is its foreground group.
- It is not handed over when stdout is piped. Whatever reads the pipe is in
  `hangar`'s job, and the first cut stopped `less` in `hangar --exec ... | less`
  by taking the terminal away from it. A command that reaches for the terminal
  in that case waits as it does above one at a time, below.

**The docs say what is true.** The README section and the doc comment above `run`
lose the caveat and say what Ctrl-C does now. The sentence about interactive
commands at one host at a time stays, because it becomes true.

## Not taken

- **The child in `hangar`'s own process group.** That is what `system(3)` does,
  and it fixes both problems with less code: the terminal and Ctrl-C reach both
  processes, and Ctrl-Z stops both for the shell to resume. But `killpg` needs the
  child to lead its own group, so the deadline would fall back to signaling the
  direct child, which reopens the `sh -c` grandchild that review item 3 on `0027`
  was about. Signaling `hangar`'s own group instead would also kill whatever else
  is in it, such as the `tee` in `hangar ... | tee log`.
- **Only ignoring SIGINT in `hangar`.** It keeps `hangar` alive, but the child
  still never receives the interrupt, so the prompt stops coming back at all.

## Open

**A command that reaches for the terminal without being handed it**, above one
at a time or with stdout piped. Its stdin is
`/dev/null`, but ssh opens `/dev/tty` for a password prompt, and from a
background group that stops it. Several commands cannot share one keyboard, so
nothing hands the terminal over. The command waits until `--timeout` or Ctrl-C
ends it, and both of those now do. `BatchMode=yes` in the ssh command avoids the
prompt altogether.

## Testing

`run` lives in the executable target, which the suite cannot reach. The parts
that are decisions move down to `HangarCore` beside `ExecPlan`: what a signal or
a child's exit status means for the run, and the exit code that results.

The process behavior can only be shown against a real terminal, so it gets evals
that drive the built binary under `script` through
`scripts/exec-terminal-check.sh`. One sends Ctrl-C at one at a time and in
parallel, and fails if any process the run started is still alive. One reads a
line from the terminal at `--parallel 1` and fails if the child is stopped. Both
failed on `main`, and each was watched failing on a planted regression, per
mistake 16. Two versions of the check passed on `main` before they were right.
The first inherited an ignored SIGINT. The second closed the pty before it
looked, and the hangup killed the orphans a real terminal would have kept.

Ctrl-Z, `fg`, a run started with `&`, `| less`, `nohup`, `| true` and SIGTERM
from another process were checked by hand, the first four under an interactive
bash on a pty.

`security-core-processes-have-a-deadline` also runs the binary now. Moving the
SIGTERM into a function the interrupt path shares left the line it greps for in
place with the deadline deleted, and the case stayed green.
