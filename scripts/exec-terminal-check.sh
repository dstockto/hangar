#!/bin/bash
# Drives the built `hangar --exec` the way a person or an agent would, because
# these promises are about processes and a terminal, which the suite cannot
# reach. `script` supplies the pty. Exits 0 when the promise held.
#
#   interrupt           Ctrl-C at one host at a time leaves nothing running
#   interrupt-parallel  the same at --parallel 2, with a member ignoring SIGTERM
#   interrupt-after-a-death  the same, after one command killed itself with SIGINT
#   interrupt-background  Ctrl-C at one host at a time, with a job started by `&`
#   reads-terminal      a command run one at a time can read the terminal
#   reads-terminal-redirected  the same with hangar's stdout sent to a file
#   deadline            --timeout, with no terminal, leaves nothing running
#   deadline-exit-zero  a host --timeout stopped fails though its command exits 0
#   reader-gone         a reader that went away stops the run with 141, unless
#                       SIGPIPE was ignored before hangar started
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

mode="${1:?usage: exec-terminal-check.sh interrupt|interrupt-parallel|interrupt-after-a-death|interrupt-background|reads-terminal|reads-terminal-redirected|deadline|deadline-exit-zero|reader-gone}"
bin=app/.build/debug/hangar-cli
swift build --package-path app --product hangar-cli >/dev/null 2>&1 || exit 1

tmp=$(mktemp -d) || exit 1
# A number nothing else on the machine is sleeping for, so pgrep finds only ours.
n=$((40000 + $$ % 10000))
job=
cleanup() {
    [[ -n "$job" ]] && pkill -P "$job" 2>/dev/null
    [[ -n "$job" ]] && kill "$job" 2>/dev/null
    pkill -9 -f "^sleep $n$" 2>/dev/null
    pkill -9 -f "^sh -c .*(sleep|got-)$n" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT

printf '%s' '{"instances": [
 {"id": "i-0000000000000000a", "state": "running", "type": "t3.small", "launchTime": "2026-08-20T15:46:42.000Z", "tags": {"product": "payments", "env": "prod", "Name": "alpha"}},
 {"id": "i-0000000000000000b", "state": "running", "type": "t3.small", "launchTime": "2026-08-20T15:46:42.000Z", "tags": {"product": "payments", "env": "prod", "Name": "beta"}}
], "region": "us-west-2", "fetchedAt": 800000000}' > "$tmp/cache"

# Runs hangar on a fresh pty, types $2 into it after two seconds, and returns
# after $3 seconds with the pty still open: closing it hangs up the session,
# which kills orphans a real terminal would have kept. Fails unless something
# matching $1 was running before the keys were typed, so a run that never
# started cannot pass. A job started by a non-interactive shell begins with
# SIGINT ignored and keeps that across exec, so without the reset Ctrl-C proves
# nothing. With CHECK_STDOUT set, hangar's stdout goes to that file instead.
drive() {
    local watch="$1" keys="$2" limit="$3"
    shift 3
    # shellcheck disable=SC2016 # the single quotes keep Perl's $SIG from the shell
    ( sleep 2; printf '%b' "$keys"; sleep 30 ) \
        | script -q /dev/null /usr/bin/perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT";
            open STDOUT, ">", $ENV{CHECK_STDOUT} or die if $ENV{CHECK_STDOUT};
            exec @ARGV' \
            "$bin" --cache "$tmp/cache" -y "$@" > "$tmp/out" 2>&1 &
    job=$!
    sleep 1.5
    pgrep -f "$watch" >/dev/null || return 1
    sleep "$limit"
}

case "$mode" in
    interrupt)
        drive "^sleep $n$" '\003' 3 --exec sh -c "sleep $n; true" || exit 1
        ! pgrep -f "sleep $n" >/dev/null && grep -q 'interrupted' "$tmp/out"
        ;;
    interrupt-parallel)
        # The subshell ignores SIGTERM and outlives its group leader, which is
        # the case only a SIGKILL to the whole group reaches.
        drive "^sleep $n$" '\003' 4 --parallel 2 \
            --exec sh -c "(trap '' TERM; sleep $n) & sleep $n; true" || exit 1
        ! pgrep -f "sleep $n" >/dev/null && grep -q 'interrupted' "$tmp/out"
        ;;
    interrupt-after-a-death)
        # alpha dies of a SIGINT nobody typed, while beta keeps going. That death
        # once marked the run interrupted, and from then on Ctrl-C was ignored.
        drive "^sleep $n$" '\003' 3 --parallel 2 \
            --exec sh -c "case \$1 in *alpha*) kill -INT \$\$;; esac; sleep $n; true" sh '{alias}' \
            || exit 1
        ! pgrep -f "sleep $n" >/dev/null && grep -q 'interrupted' "$tmp/out"
        ;;
    interrupt-background)
        # A shell starts its `&` jobs ignoring SIGINT, so this one outlives the
        # leader Ctrl-C killed unless the run ends the leader's group.
        drive "^sleep $n$" '\003' 3 --exec sh -c "(sleep $n) & sleep $n; true" || exit 1
        ! pgrep -f "sleep $n" >/dev/null && grep -q 'interrupted' "$tmp/out"
        ;;
    reads-terminal)
        drive "^sh -c read x; echo got-$n" 'hello\n' 3 alpha --exec sh -c "read x; echo got-$n:\$x" || exit 1
        ! pgrep -f "got-$n" >/dev/null && grep -q "got-$n:hello" "$tmp/out"
        ;;
    reads-terminal-redirected)
        # A file has no reader in this job that needs the terminal, so the
        # command still gets it. Only a pipe is a reason to keep it.
        export CHECK_STDOUT="$tmp/redirected"
        drive "^sh -c read x; echo got-$n" 'hello\n' 3 alpha --exec sh -c "read x; echo got-$n:\$x" || exit 1
        ! pgrep -f "got-$n" >/dev/null && grep -q "got-$n:hello" "$tmp/redirected"
        ;;
    deadline)
        "$bin" --cache "$tmp/cache" -y alpha --timeout 1 \
            --exec sh -c "(trap '' TERM; sleep $n) & sleep $n; true" \
            < /dev/null > "$tmp/out" 2>&1 &
        job=$!
        sleep 0.5
        pgrep -f "^sleep $n$" >/dev/null || exit 1
        # Bounded, because the failure being checked for is a run with no end.
        for _ in $(seq 1 80); do
            kill -0 "$job" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$job" 2>/dev/null && exit 1
        wait "$job"
        status=$?
        job=
        [[ $status -eq 4 ]] && ! pgrep -f "sleep $n" >/dev/null \
            && grep -q 'did not finish within 1 second' "$tmp/out"
        ;;
    deadline-exit-zero)
        # The command answers the deadline's SIGTERM by exiting 0, which a shell
        # can also do on its own, and was once counted as the host succeeding.
        "$bin" --cache "$tmp/cache" -y alpha --timeout 1 \
            --exec sh -c "trap 'exit 0' TERM; sleep $n & wait" \
            < /dev/null > "$tmp/out" 2>&1
        status=$?
        [[ $status -eq 4 ]] && ! pgrep -f "sleep $n" >/dev/null \
            && grep -q 'timed out' "$tmp/out"
        ;;
    reader-gone)
        # The pipe's read end is closed before hangar starts, so every write to
        # stdout fails and nothing depends on timing. Python ignores SIGPIPE
        # itself, so restore_signals decides what hangar inherits.
        # shellcheck disable=SC2016 # the single quotes are Python's, not the shell's
        /usr/bin/python3 -I -c '
import os, subprocess, sys
def run(restore):
    r, w = os.pipe()
    os.close(r)
    p = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=w,
                       stderr=subprocess.PIPE, restore_signals=restore)
    os.close(w)
    return p.returncode, p.stderr.decode()
code, err = run(True)
ignored, _ = run(False)
sys.exit(0 if code == 141 and "interrupted" in err and ignored == 0 else 1)
' "$bin" --cache "$tmp/cache" -y --parallel 2 --exec sh -c 'echo hi'
        ;;
    *)
        echo "unknown mode: $mode" >&2
        exit 2
        ;;
esac
