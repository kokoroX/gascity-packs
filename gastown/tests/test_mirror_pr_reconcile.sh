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
  bd:update)
    case " $* " in *" ${GC_TEST_FAIL_WORK:-__no_failure__} "*) exit 1 ;; esac ;;
  bd:close|mail:send) : ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/bin/gc"
export PATH="$TMP/bin:$PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset_case() {
    : >"$GC_TEST_LOG"
    rm -rf "$STATE"
    jq -n --arg head "$HEAD_SHA" '[{id:"work-1",status:"blocked",metadata:{merge_strategy:"mirror-pr",merge_result:"pull_request_pending",target:"main",pr_branch:"gc-pr/main/work-1",pr_head:$head,mirror_pr_reconcile_pending:"true",mirror_pr_origin:$origin}}]' --arg origin "$TMP/origin.git" >"$GC_TEST_LIST"
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

reset_case
sh "$COMMAND" record work-1 main "$HEAD_SHA"
contains "<mirror_pr_origin=$TMP/origin.git>"
contains '<--assignee=rig/refinery>'

reset_case
jq '.[0].metadata.mirror_pr_origin = "/other/origin.git"' "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
write_state open "$HEAD_SHA" ''
sh "$COMMAND"
! grep -F 'gc <bd> <update>' "$GC_TEST_LOG" >/dev/null || fail 'foreign bead was updated'
! grep -F 'gc <mail> <send>' "$GC_TEST_LOG" >/dev/null || fail 'foreign bead was escalated'

reset_case
jq 'del(.[0].metadata.mirror_pr_origin)' "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
sh "$COMMAND"
! grep -F 'gc <bd> <update>' "$GC_TEST_LOG" >/dev/null || fail 'legacy bead without state was updated'
write_state open "$HEAD_SHA" ''
sh "$COMMAND"
contains "<mirror_pr_origin=$TMP/origin.git>"
! grep -F '<--assignee=' "$GC_TEST_LOG" >/dev/null || fail 'reconciliation changed assignee'

reset_case
jq --arg head "$HEAD_SHA" --arg origin "$TMP/origin.git" '
  def bead($id; $origin; $status; $result):
    {id:$id,status:$status,metadata:{merge_strategy:"mirror-pr",merge_result:$result,
     target:"main",pr_branch:("gc-pr/main/"+$id),pr_head:$head,
     mirror_pr_reconcile_pending:"true",mirror_pr_origin:$origin}};
  [bead("a-fail";$origin;"blocked";"pull_request_pending"),
   bead("b-merged";$origin;"blocked";"pull_request_pending"),
   bead("c-open";$origin;"blocked";"pull_request_pending"),
   bead("d-foreign";"/other/origin.git";"blocked";"pull_request_pending"),
   bead("e-foreign-closed";"/other/origin.git";"closed";"mirror_pr_merged")]' \
   "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
for work in a-fail b-merged c-open d-foreign e-foreign-closed; do
    state=open
    [ "$work" != b-merged ] || state=merged
    jq -n --arg work "$work" --arg head "$HEAD_SHA" --arg state "$state" \
        '{work:$work,branch:("gc-pr/main/"+$work),target:"main",head_sha:$head,state:$state,merge_sha:$head}' \
        >"$TMP/origin.git/gc-pr-state/$work.json"
done
export GC_TEST_FAIL_WORK=a-fail
if sh "$COMMAND" --all >"$TMP/all-output"; then fail '--all did not report failure'; fi
unset GC_TEST_FAIL_WORK
contains 'gc <bd> <close> <--rig=rig> <b-merged>'
contains '<c-open>'
! grep -F '<d-foreign>' "$GC_TEST_LOG" >/dev/null || fail 'foreign blocked bead was touched'
! grep -F '<e-foreign-closed>' "$GC_TEST_LOG" >/dev/null || fail 'foreign closed bead was touched'
! grep -F '<--assignee=' "$GC_TEST_LOG" >/dev/null || fail 'batch changed assignee'
grep -F 'FAILED: a-fail' "$TMP/all-output" >/dev/null || fail 'missing failed result'
grep -F 'MERGED: closed b-merged' "$TMP/all-output" >/dev/null || fail 'missing merged result'
grep -F 'PENDING: c-open' "$TMP/all-output" >/dev/null || fail 'missing open result'
[ "$(wc -l <"$TMP/all-output" | tr -d ' ')" = 3 ] || fail 'expected one result line per bead'

printf 'Mirror PR reconciliation tests passed\n'
