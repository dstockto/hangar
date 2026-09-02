#!/bin/bash
# Tests production-gate.sh. Every gate needs a case that fires and a case that
# must not, because a gate with false positives is worse than no gate.
cd "$(dirname "$0")" || exit 1

gate=./production-gate.sh
pass=0
fail=0

verdict() {
    printf '{"tool_input":{"command":%s}}' "$(/usr/bin/python3 -c \
        'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
        | bash "$gate" >/dev/null 2>&1 && echo allow || echo block
}

check() {
    local want="$1" cmd="$2" got
    got="$(verdict "$cmd")"
    if [[ "$got" == "$want" ]]; then
        printf '  ok    %-6s %s\n' "$got" "$cmd"
        pass=$((pass + 1))
    else
        printf '  FAIL  wanted %s, got %s: %s\n' "$want" "$got" "$cmd"
        fail=$((fail + 1))
    fi
}

echo "must be blocked"
check block 'git push --force origin main'
check block 'git push -f origin main'
check block 'git push --force-with-lease origin main'
check block 'cd /repo && git push --force origin main'
check block 'GIT_TRACE=1 git push --force origin main'
check block 'gh release delete v0.2.0 --yes'
check block 'gh repo edit owner/repo --visibility public'
check block 'xcrun notarytool submit out.dmg --wait'
check block 'cat ~/.aws/credentials'
check block 'head -5 ~/.aws/sso/cache/abc.json'
check block 'cp ~/.ssh/id_ed25519 /tmp/k'

echo
echo "must be allowed"
check allow 'make test'
check allow 'git push origin main'
check allow 'git log --oneline -5'
check allow 'gh release list'
check allow 'gh release view v0.0.1'
check allow "echo 'git push --force is blocked by the gate'"
check allow "grep -rn 'gh release delete' docs/"
check allow 'evals/check.sh'
check allow 'swift build --package-path app'
check allow 'ls ~/.aws'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
