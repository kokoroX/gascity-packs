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

mkdir -p "$TMP/origin.git" "$TMP/seed"
git -C "$TMP/origin.git" init -q --bare --initial-branch=main
git -C "$TMP/seed" init -q --initial-branch=main
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
git -C "$TMP" clone -q "$TMP/origin.git" "$TMP/clone"
export GC_TEST_REAL_GIT
GC_TEST_REAL_GIT=$(command -v git)

cat >"$TMP/bin/git" <<'SH'
#!/bin/sh
for arg in "$@"; do
  if [ -n "${GC_TEST_FAIL_LS_REF:-}" ] && [ "$arg" = "$GC_TEST_FAIL_LS_REF" ]; then
    exit 1
  fi
done
exec "$GC_TEST_REAL_GIT" "$@"
SH
chmod +x "$TMP/bin/git"

cat >"$TMP/bin/gc" <<'SH'
#!/bin/sh
printf 'gc' >>"$GC_TEST_LOG"
for arg in "$@"; do printf ' <%s>' "$arg" >>"$GC_TEST_LOG"; done
printf '\n' >>"$GC_TEST_LOG"
case "$1:$2" in
  bd:list) cat "$GC_TEST_LIST" ;;
  bd:update)
    case " $* " in *" ${GC_TEST_FAIL_WORK:-__no_failure__} "*) exit 1 ;; esac
    shift 2
    case "${1:-}" in --rig=*) shift ;; esac
    work=$1
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --set-metadata)
          key=${2%%=*}; value=${2#*=}
          jq --arg work "$work" --arg key "$key" --arg value "$value" 'map(if .id == $work then .metadata[$key] = $value else . end)' "$GC_TEST_LIST" >"$GC_TEST_LIST.tmp"
          mv "$GC_TEST_LIST.tmp" "$GC_TEST_LIST"
          shift 2 ;;
        --unset-metadata)
          jq --arg work "$work" --arg key "$2" 'map(if .id == $work then del(.metadata[$key]) else . end)' "$GC_TEST_LIST" >"$GC_TEST_LIST.tmp"
          mv "$GC_TEST_LIST.tmp" "$GC_TEST_LIST"
          shift 2 ;;
        *) shift ;;
      esac
    done ;;
  bd:show) cat "$GC_TEST_LIST" ;;
  gastown:task-artifact-cleanup)
    if [ "${GC_TEST_CLEANUP_BLOCKED:-0}" = 1 ]; then
      jq '.[0].metadata.artifact_cleanup_state = "blocked"' "$GC_TEST_LIST" >"$GC_TEST_LIST.tmp"
      mv "$GC_TEST_LIST.tmp" "$GC_TEST_LIST"
      exit 1
    fi
    [ "${GC_TEST_CLEANUP_FAIL:-0}" = 0 ] ;;
  bd:close) : ;;
  mail:send) [ "${GC_TEST_MAIL_FAIL:-0}" = 0 ] ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/bin/gc"
export PATH="$TMP/bin:$PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset_case() {
    : >"$GC_TEST_LOG"
    git --git-dir="$TMP/origin.git" update-ref -d refs/gc-pr-state/work-1
    jq -n --arg head "$HEAD_SHA" '[{id:"work-1",status:"blocked",metadata:{merge_strategy:"mirror-pr",merge_result:"pull_request_pending",target:"main",pr_branch:"gc-pr/main/work-1",pr_head:$head,mirror_pr_reconcile_pending:"true",mirror_pr_origin:$origin}}]' --arg origin "$TMP/origin.git" >"$GC_TEST_LIST"
}
write_ref() {
    local work=$1 filename=$2 blob tree commit
    blob=$(git --git-dir="$TMP/origin.git" hash-object -w --stdin)
    tree=$(printf '100644 blob %s\t%s\n' "$blob" "$filename" | git --git-dir="$TMP/origin.git" mktree)
    commit=$(printf 'state\n' | git --git-dir="$TMP/origin.git" -c user.name=Test -c user.email=test@example.invalid commit-tree "$tree")
    git --git-dir="$TMP/origin.git" update-ref "refs/gc-pr-state/$work" "$commit"
}
write_state() {
    jq -n --arg state "$1" --arg head "$2" --arg merge "$3" \
        '{work:"work-1",branch:"gc-pr/main/work-1",target:"main",head_sha:$head,state:$state,merge_sha:$merge,pr_url:"https://example.invalid/pr/1"}' | write_ref work-1 state.json
}
no_close() { ! grep -F 'gc <bd> <close>' "$GC_TEST_LOG" >/dev/null || fail 'unexpected close'; }
contains() { grep -F "$1" "$GC_TEST_LOG" >/dev/null || fail "missing call: $1"; }

reset_case
git -C "$TMP/seed" checkout -q -b integration origin/main
git -C "$TMP/seed" merge -q --no-ff -m integration "$HEAD_SHA"
git -C "$TMP/seed" push -q origin HEAD:refs/heads/main
sh "$COMMAND"
contains 'gc <bd> <close>'
contains '<merge_result=mirror_pr_merged>'
contains '<merged_via=ancestry>'
contains 'gc <gastown> <task-artifact-cleanup> <work-1>'
[ "$(jq -r '.[0].metadata.mirror_pr_reconcile_pending // empty' "$GC_TEST_LIST")" = '' ] || fail 'ancestry merge retained marker'
if git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1; then
    fail 'ancestry merge did not delete mirror branch'
fi
git -C "$TMP/seed" push -q --force origin origin/main~1:refs/heads/main
git -C "$TMP/seed" push -q origin "$HEAD_SHA:refs/heads/gc-pr/main/work-1"

reset_case
sh "$COMMAND"
no_close
git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1 || fail 'unmerged mirror branch deleted'
write_state open "$HEAD_SHA" ''
sh "$COMMAND" >"$TMP/open-output"
no_close
grep -F 'PENDING: work-1 — mirror PR is open.' "$TMP/open-output" >/dev/null || fail 'open PR did not remain pending'
git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1 || fail 'open PR mirror branch deleted'
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
printf '{}\n' | write_ref work-1 wrong.json
if sh "$COMMAND" >"$TMP/invalid-output" 2>&1; then fail 'invalid state tree accepted'; fi
grep -F 'cannot read valid state for work-1' "$TMP/invalid-output" >/dev/null || fail 'invalid tree did not follow invalid state path'
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
git -C "$TMP/seed" push -q origin "$HEAD_SHA:refs/heads/gc-pr/main/work-1"
jq '.[0].status = "closed"' "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
sh "$COMMAND"
no_close
contains '<merge_result=mirror_pr_merged>'
contains '<merged_via=ancestry>'
contains 'gc <gastown> <task-artifact-cleanup> <work-1>'
[ "$(jq -r '.[0].metadata.mirror_pr_reconcile_pending // empty' "$GC_TEST_LIST")" = '' ] || fail 'closed merged marker retained'
if git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1; then
    fail 'closed merged branch not deleted'
fi

reset_case
git -C "$TMP/seed" push -q origin "$HEAD_SHA:refs/heads/gc-pr/main/work-1"
git -C "$TMP/seed" push -q --force origin origin/main~1:refs/heads/main
jq '.[0].status = "closed"' "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
sh "$COMMAND"
no_close
contains '<mirror_pr_error=closed externally without merge evidence; mirror branch left>'
contains 'gc <mail> <send> <mayor/>'
git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1 || fail 'unmerged branch deleted'

reset_case
export GC_MIRROR_PR_AWAIT_ALERT_SECONDS=0
sh "$COMMAND"
sh "$COMMAND"
[ "$(grep -c 'gc <mail> <send>' "$GC_TEST_LOG")" = 1 ] || fail 'alert was not sent exactly once'
[ -n "$(jq -r '.[0].metadata.mirror_pr_alerted_at // empty' "$GC_TEST_LIST")" ] || fail 'missing alert timestamp'
export GC_MIRROR_PR_AWAIT_ALERT_SECONDS=invalid
if sh "$COMMAND"; then fail 'invalid alert threshold accepted'; fi
unset GC_MIRROR_PR_AWAIT_ALERT_SECONDS

git -C "$TMP/seed" push -q origin "$HEAD_SHA:refs/heads/main"
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
        | write_ref "$work" state.json
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
grep -F 'MERGED: closed c-open' "$TMP/all-output" >/dev/null || fail 'missing ancestry result'
[ "$(wc -l <"$TMP/all-output" | tr -d ' ')" = 3 ] || fail 'expected one result line per bead'

reset_case
jq '.[0].status = "closed" | .[0].metadata.merge_result = "mirror_pr_merged"' "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
export GC_TEST_CLEANUP_BLOCKED=1 GC_TEST_MAIL_FAIL=1
if sh "$COMMAND"; then fail 'failed notification accepted'; fi
[ "$(jq -r '.[0].metadata.mirror_pr_reconcile_pending // empty' "$GC_TEST_LIST")" = true ] || fail 'failed notification cleared marker'
unset GC_TEST_MAIL_FAIL
if sh "$COMMAND"; then fail 'blocked cleanup accepted'; fi
unset GC_TEST_CLEANUP_BLOCKED
contains 'gc <mail> <send> <mayor/>'
[ -z "$(jq -r '.[0].metadata.mirror_pr_reconcile_pending // empty' "$GC_TEST_LIST")" ] || fail 'blocked cleanup retained marker'
if git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/gc-pr/main/work-1; then
    fail 'blocked cleanup left the mirror branch'
fi

git -C "$TMP/seed" push -q --force origin origin/main~1:refs/heads/main
reset_case
jq --arg origin "$TMP/origin.git" --arg head "$HEAD_SHA" '
  [{id:"a-closed",status:"closed",metadata:{merge_strategy:"mirror-pr",merge_result:"mirror_pr_merged",target:"main",pr_branch:"gc-pr/main/a-closed",pr_head:$head,mirror_pr_reconcile_pending:"true",mirror_pr_origin:$origin}},
   {id:"b-blocked",status:"blocked",metadata:{merge_strategy:"mirror-pr",merge_result:"pull_request_pending",target:"main",pr_branch:"gc-pr/main/b-blocked",pr_head:$head,mirror_pr_reconcile_pending:"true",mirror_pr_origin:$origin}}]' "$GC_TEST_LIST" >"$TMP/next.json"
mv "$TMP/next.json" "$GC_TEST_LIST"
export GC_TEST_CLEANUP_FAIL=1
if sh "$COMMAND"; then fail 'cleanup failure accepted'; fi
unset GC_TEST_CLEANUP_FAIL
sh "$COMMAND" >"$TMP/starvation-output"
grep -F 'PENDING: b-blocked' "$TMP/starvation-output" >/dev/null || fail 'failed closed bead starved the blocked bead'
! grep -F 'gc <bd> <close>' "$GC_TEST_LOG" >/dev/null || fail 'blocked bead was closed while unmerged'

reset_case
git -C "$TMP/clone" config remote.origin.url /repos-nonexistent/mirrors/origin.git
git -C "$TMP/clone" config url."$TMP/origin.git".insteadOf /repos-nonexistent/mirrors/origin.git
sh "$COMMAND" record work-1 main "$HEAD_SHA"
contains '<mirror_pr_origin=/repos-nonexistent/mirrors/origin.git>'
write_state closed "$HEAD_SHA" ''
if sh "$COMMAND"; then fail 'closed PR via insteadOf accepted'; fi
contains '<gc.routed_to=human>'
contains 'gc <mail> <send> <mayor/>'
git -C "$TMP/clone" config remote.origin.url "$TMP/origin.git"
git -C "$TMP/clone" config --unset url."$TMP/origin.git".insteadOf

reset_case
export GC_TEST_FAIL_LS_REF='refs/gc-pr-state/*'
if sh "$COMMAND" >"$TMP/ls-fail-output" 2>&1; then fail 'failed sweep ls-remote accepted'; fi
! grep -F 'No pending mirror PRs.' "$TMP/ls-fail-output" >/dev/null || fail 'failed sweep treated as no state'
unset GC_TEST_FAIL_LS_REF
export GC_TEST_FAIL_LS_REF=refs/gc-pr-state/work-1
if sh "$COMMAND" >"$TMP/ls-fail-output" 2>&1; then fail 'failed individual ls-remote accepted'; fi
! grep -F 'mirror has not produced a state file' "$TMP/ls-fail-output" >/dev/null || fail 'failed individual lookup treated as no state'
no_close
unset GC_TEST_FAIL_LS_REF

printf 'Mirror PR reconciliation tests passed\n'
