#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMMAND="$ROOT/gastown/commands/mirror-pr-reconcile/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
export GC_AGENT=rig/refinery GC_RIG=rig GC_TEST_LOG="$TMP/calls" GC_TEST_LIST="$TMP/list.json"
export GC_REPO_ROOT="$TMP/clone"

git init -q --bare --initial-branch=main "$TMP/origin.git"
git init -q --initial-branch=main "$TMP/seed"
git -C "$TMP/seed" config user.name Test
git -C "$TMP/seed" config user.email test@example.invalid
printf 'base\n' >"$TMP/seed/file"
git -C "$TMP/seed" add file
git -C "$TMP/seed" commit -qm base
git -C "$TMP/seed" remote add origin "$TMP/origin.git"
git -C "$TMP/seed" push -q origin main
printf 'work\n' >>"$TMP/seed/file"
git -C "$TMP/seed" commit -qam work
HEAD_SHA=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin HEAD:refs/heads/gc-pr/main/work-1
git clone -q "$TMP/origin.git" "$TMP/clone"
mkdir -p "$TMP/origin.git/gc-pr-state"
STATE="$TMP/origin.git/gc-pr-state/work-1.json"

cat >"$TMP/bin/gc" <<'SH'
#!/bin/sh
printf 'gc' >>"$GC_TEST_LOG"
for arg in "$@"; do printf ' <%s>' "$arg" >>"$GC_TEST_LOG"; done
printf '\n' >>"$GC_TEST_LOG"
case "$1:$2" in
  bd:list) cat "$GC_TEST_LIST" ;;
  bd:update|bd:close|mail:send) : ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/bin/gc"
export PATH="$TMP/bin:$PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset_case() {
    : >"$GC_TEST_LOG"
    rm -rf "$STATE"
    jq -n --arg head "$HEAD_SHA" '[{id:"work-1",status:"blocked",metadata:{merge_strategy:"mirror-pr",merge_result:"pull_request_pending",target:"main",pr_branch:"gc-pr/main/work-1",pr_head:$head,mirror_pr_reconcile_pending:"true"}}]' >"$GC_TEST_LIST"
}
write_state() {
    jq -n --arg state "$1" --arg head "$2" --arg merge "$3" \
        '{work:"work-1",branch:"gc-pr/main/work-1",target:"main",head_sha:$head,state:$state,merge_sha:$merge,pr_url:"https://example.invalid/pr/1"}' >"$STATE"
}
no_close() { ! grep -F 'gc <bd> <close>' "$GC_TEST_LOG" >/dev/null || fail 'unexpected close'; }
contains() { grep -F "$1" "$GC_TEST_LOG" >/dev/null || fail "missing call: $1"; }

reset_case
sh "$COMMAND"
no_close
write_state open "$HEAD_SHA" ''
sh "$COMMAND"
no_close
contains '<pr_url=https://example.invalid/pr/1>'

reset_case
write_state merged "$HEAD_SHA" "$HEAD_SHA"
if sh "$COMMAND"; then fail 'unreachable merge accepted'; fi
no_close
contains 'gc <mail> <send> <mayor/>'

reset_case
write_state merged 0000000000000000000000000000000000000000 "$HEAD_SHA"
if sh "$COMMAND"; then fail 'changed head accepted'; fi
no_close
contains 'gc <mail> <send> <mayor/>'

reset_case
write_state closed "$HEAD_SHA" ''
if sh "$COMMAND"; then fail 'closed PR accepted'; fi
no_close
contains '<gc.routed_to=human>'
contains 'gc <mail> <send> <mayor/>'

reset_case
mkdir "$STATE"
if sh "$COMMAND"; then fail 'unreadable state accepted'; fi
no_close

reset_case
write_state merged "$HEAD_SHA" "$HEAD_SHA"
git -C "$TMP/seed" push -q origin HEAD:refs/heads/main
sh "$COMMAND"
contains 'gc <bd> <close>'
contains '<mirror_pr_reconcile_pending>'
if git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1; then
    fail 'merged mirror branch not deleted'
fi

printf 'Mirror PR reconciliation tests passed\n'
