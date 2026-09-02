#!/bin/bash
# Runs the eval cases. Each case's command is the verdict: exit 0 passes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

filter="${1:-}"
pass=0 fail=0 failed=()

for case in evals/*.json; do
    id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$case")"
    [[ -n "$filter" && "$id" != "$filter"* ]] && continue
    command="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["command"])' "$case")"
    promise="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["promise"])' "$case")"

    if bash -c "$command" >/dev/null 2>&1; then
        printf '  \033[0;32mpass\033[0m  %s\n' "$id"
        pass=$((pass + 1))
    else
        printf '  \033[0;31mFAIL\033[0m  %s\n        %s\n' "$id" "$promise"
        fail=$((fail + 1))
        failed+=("$id")
    fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
if (( fail > 0 )); then
    printf 'broken promises: %s\n' "${failed[*]}"
    exit 1
fi
