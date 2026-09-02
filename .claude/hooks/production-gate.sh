#!/bin/bash
# Stops the handful of commands in this repo that are irreversible in public, and
# the reads that would put someone else's credentials into a transcript.
#
# Reads the tool call on stdin as JSON, exits 0 to allow, exits 2 with a reason on
# stderr to block. Advisory by design: it catches the mistake of the moment, it is
# not a security boundary.
#
# It matches on what is being *invoked*, not on the command text. An earlier
# version used substring matching and blocked commands that merely mentioned a
# gated phrase inside a quoted string, including the commit that tried to fix it.
# A gate with false positives teaches people to route around the gate.
set -uo pipefail

payload="$(cat)"
command="$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null || true)"

[[ -z "$command" ]] && exit 0

block() {
    printf 'production-gate: %s\n' "$1" >&2
    exit 2
}

# True when some segment of the command actually runs `program` and that segment
# contains every one of the remaining patterns.
invokes() {
    local program="$1"
    shift
    local segment pattern found
    while IFS= read -r segment; do
        # Trim, then step past leading env assignments and sudo.
        segment="${segment#"${segment%%[![:space:]]*}"}"
        while [[ "$segment" == [A-Za-z_]*=* && "${segment%%=*}" != *[[:space:]]* ]]; do
            [[ "$segment" == *[[:space:]]* ]] || break
            segment="${segment#*[[:space:]]}"
            segment="${segment#"${segment%%[![:space:]]*}"}"
        done
        segment="${segment#sudo }"

        [[ "$segment" == "$program" || "$segment" == "$program "* ]] || continue
        found=yes
        for pattern in "$@"; do
            [[ "$segment" == *"$pattern"* ]] || { found=no; break; }
        done
        [[ "$found" == yes ]] && return 0
        # The trailing newline matters: `read` returns false on a final line
        # without one, so the loop body would never run for a single-segment
        # command, and every gate would silently allow everything.
    done < <(printf '%s\n' "$command" | tr ';|&' '\n')
    return 1
}

# History rewrites and release deletions are not recoverable once published.
if invokes git push --force || invokes git push --force-with-lease || invokes git "push -f"; then
    block "rewriting published history is the owner's call. Confirm, then run it yourself."
fi

if invokes gh "release delete"; then
    block "deleting a published release breaks the in-app updater for anyone on it. Confirm first."
fi

if invokes gh "repo edit" --visibility; then
    block "repository visibility is a one-way door. The owner does this, not the agent."
fi

if invokes xcrun "notarytool submit"; then
    block "notarization submits the binary to Apple. Run make dmg deliberately, not incidentally."
fi

# Credential material never belongs in a transcript, whatever is reading it.
for reader in cat less more head tail bat open cp mv strings xxd hexdump od; do
    for secret in /.aws/credentials /.aws/sso/cache /.ssh/id_; do
        if invokes "$reader" "$secret"; then
            block "that path holds credential material. Use the fixtures in app/Tests instead."
        fi
    done
done

exit 0
