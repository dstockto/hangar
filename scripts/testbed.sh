#!/bin/bash
# Drives every host source, the merge and the ssh_config writer against a
# fabricated home directory, then proves the developer's own files were not
# touched.
#
# The proof matters. expandingTildeInPath reads the real home on macOS whatever
# HOME says, so a testbed built on an environment variable would quietly read and
# rewrite ~/.ssh/config. Every path here is explicit, and the fingerprint check at
# the end is the belt to that braces.
# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

ROOT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/hangar-testbed.XXXXXX")}"
KEEP="${HANGAR_TESTBED_KEEP:-0}"

# Everything of the user's that this must never touch.
GUARDED=(
    "$HOME/.ssh/config"
    "$HOME/.ssh/config.d/hangar"
    "$HOME/.hangar/config.json"
    "$HOME/.hangar/hosts.csv"
    "$HOME/.hangar/cache/instances.json"
)

fingerprint() {
    for path in "${GUARDED[@]}"; do
        if [[ -e "$path" ]]; then
            printf '%s %s\n' "$path" "$(shasum -a 256 "$path" | cut -d' ' -f1)"
        else
            printf '%s absent\n' "$path"
        fi
    done
}

build_home() {
    mkdir -p "$ROOT/.ssh/config.d" "$ROOT/.hangar"
    chmod 700 "$ROOT/.ssh"

    # A realistic hand-grown ssh config: a defaults block, a jump host, a Match
    # block, an Include, several naming conventions, and the hostile cases.
    cat > "$ROOT/.ssh/config" <<'EOF'
# The kind of file that accumulates over four years.
Host *
  ServerAliveInterval 60
  AddKeysToAgent yes

Host bastion jump
  HostName bastion.example.com
  User ec2-user
  Port 2222

Match host *.internal exec "test -f /tmp/never"
  ProxyJump bastion
  User root

Include config.d/work

Host payments-prod-web-1
  HostName 10.20.30.10
  User ec2-user

Host payments-prod-web-2
  HostName 10.20.30.11
  User ec2-user

Host payments-prod-db
  HostName 10.20.30.40
  User postgres

Host payments-staging-web-1
  HostName 10.21.30.10
  User ec2-user

Host search-qa-node-1
  HostName 10.22.30.10

Host search-qa-node-2
  HostName 10.22.30.11

Host web1.prod.acme.com
  User deploy

Host web2.prod.acme.com
  User deploy

Host lonely-box
  HostName 10.30.0.1

# The entries every developer's config has, which are git remote credentials
# rather than machines.
Host github-personal
  HostName github.com
  IdentityFile ~/.ssh/id_ed25519

Host bitbucket.org
  HostName bitbucket.org

Host work-gitlab
  HostName gitlab.internal.example.com
  User git

# Named for git, logged into as a person: still a host.
Host git-runner-1
  HostName 10.50.0.1
  User ec2-user

# A wildcard record in a real config, which as a Host name would become a
# catch-all sitting above everything the user has.
Host *.wildcard.example.com
  User nobody

Host prod-*
  User ec2-user
EOF

    cat > "$ROOT/.ssh/config.d/work" <<'EOF'
Host billing-prod-api-1
  HostName 10.40.0.10
  User svc-billing

Host billing-prod-api-2
  HostName 10.40.0.11
  User svc-billing
EOF

    # Exported from a spreadsheet, complete with the rows a real export has.
    printf '%s\r\n' \
        'alias,hostname,user,port,product,env,role,datacenter' \
        'legacy-dc-app-1,192.168.10.5,root,22,legacy,prod,app,ams3' \
        'legacy-dc-app-2,192.168.10.6,root,22,legacy,prod,app,ams3' \
        'legacy-dc-db,192.168.10.20,postgres,5432,legacy,prod,db,ams3' \
        '*,10.0.0.1,root,22,evil,prod,catchall,ams3' \
        'has space,10.0.0.2,root,22,bad,prod,app,ams3' \
        'legacy-dc-app-1,192.168.10.7,root,22,legacy,prod,app,ams3' \
        > "$ROOT/.hangar/hosts.csv"

    chmod 600 "$ROOT/.hangar/hosts.csv"
}

info "Testbed at $ROOT"
before="$(fingerprint)"
build_home

"$APP_DIR/.build/debug/hangar-probe" --testbed "$ROOT"
status=$?

# The command line tool, against a cache built here rather than the developer's.
# Documented as shipping, so it is proved to run, not assumed to.
CLI="$APP_DIR/.build/debug/hangar-cli"
CACHE="$ROOT/.hangar/cache/instances.json"
CLI_CONFIG="$ROOT/.hangar/config.json"
mkdir -p "$(dirname "$CACHE")"
cat > "$CACHE" <<'EOF'
{"region":"us-west-2","fetchedAt":779000000,
 "instances":[
   {"id":"i-0000000000000000a","state":"running","type":"t3.small",
    "privateIP":"10.0.0.5","availabilityZone":"us-west-2a",
    "launchTime":"2026-08-20T15:46:42.000Z",
    "tags":{"product":"payments","env":"prod","Name":"web","hostname":"web.example.com"}},
   {"id":"i-0000000000000000b","state":"stopped","type":"t3.small",
    "privateIP":"10.0.0.6","availabilityZone":"us-west-2a",
    "launchTime":"2026-08-20T15:46:42.000Z",
    "tags":{"product":"payments","env":"qa","Name":"db","hostname":"db.example.com"}}]}
EOF
chmod 600 "$CACHE"

# The tag mapping has to come from here too. Without it the command reads the
# developer's own ~/.hangar/config.json, and a fleet whose config resolves
# `product` from `Name` produced different aliases than this expects, on a
# machine where nothing was wrong.
echo '{}' > "$CLI_CONFIG"
chmod 600 "$CLI_CONFIG"

echo
echo "command line"
cli_aliases="$("$CLI" --config "$CLI_CONFIG" --cache "$CACHE" -a 2>/dev/null)"
if [[ "$cli_aliases" == $'payments-prod-web\npayments-qa-db' ]]; then
    echo "  ok   hangar lists the cached fleet, in menu order"
else
    echo "  FAIL hangar listed: $cli_aliases"
    status=1
fi
if [[ "$("$CLI" --config "$CLI_CONFIG" --cache "$CACHE" -a -s 'qa db' 2>/dev/null)" == "payments-qa-db" ]]; then
    echo "  ok   a fuzzy query reaches the host it names"
else
    echo "  FAIL the fuzzy query did not find payments-qa-db"
    status=1
fi
# Captured rather than tested inline: this script runs under set -e, and the
# non-zero exit is the thing being checked.
rc=0; "$CLI" --config "$CLI_CONFIG" --cache "$CACHE" -s "nothing-like-this" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
    echo "  ok   nothing matched exits 1, so a pipeline can tell"
else
    echo "  FAIL a query matching nothing did not exit 1"
    status=1
fi
rc=0; "$CLI" --config "$CLI_CONFIG" --cache "$ROOT/.hangar/absent.json" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
    echo "  ok   no cache exits 2, which is not the same as no matches"
else
    echo "  FAIL a missing cache did not exit 2"
    status=1
fi

after="$(fingerprint)"
if [[ "$before" != "$after" ]]; then
    echo
    diff <(echo "$before") <(echo "$after") || true
    die "the testbed changed a file outside its own root"
fi
info "your own ssh config and ~/.hangar are byte for byte unchanged"

if [[ "$KEEP" == "1" ]]; then
    info "kept: $ROOT"
else
    rm -rf "$ROOT"
fi
exit $status
