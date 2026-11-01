#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/witness-patrol-tick.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export GC_CALLS="$tmp/calls" GC_SESSIONS="$tmp/sessions" GC_AGENTS="$tmp/agents" GC_HELD="$tmp/held"
cat >"$tmp/bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_CALLS"
case "$*" in
  'agent list --json') cat "$GC_AGENTS" ;;
  'session list --json') cat "$GC_SESSIONS" ;;
  'bd --rig '*' list '*)
    case "$*" in *"--assignee=alpha/held.witness"*|*"--assignee=alpha/sleepheld.witness"*) cat "$GC_HELD" ;; *) printf '[]\n' ;; esac ;;
  'bd --rig '*' mol wisp '*) printf '{"new_epic_id":"wi-new"}\n' ;;
  'bd --rig '*' update '*) case "$*" in *"--assignee=alpha/fail.witness"*) exit 1 ;; esac ;;
  'bd --rig '*' mol burn '*) ;;
  'session nudge '*) ;;
  *) printf 'unexpected call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gc"
export PATH="$tmp/bin:$PATH"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_tick() {
  : >"$GC_CALLS"
  RC=0
  bash "$SCRIPT" >"$tmp/out" 2>"$tmp/err" || RC=$?
}
printf '%s\n' '{"agents":[]}' >"$GC_AGENTS"
printf '%s\n' '{"sessions":[]}' >"$GC_SESSIONS"
printf '%s\n' '[]' >"$GC_HELD"
run_tick
[ "$RC" -eq 0 ] && grep -Fxq 'no witness agents' "$tmp/out" || fail "empty roster: $(cat "$tmp/err")"
[ "$(wc -l <"$GC_CALLS" | tr -d ' ')" -eq 1 ] || fail 'empty roster made extra calls'

printf '%s\n' '{"agents":[{"qualified_name":"alpha/fail.witness"},{"qualified_name":"alpha/held.witness"},{"qualified_name":"alpha/sleepheld.witness"},{"qualified_name":"beta/witness"},{"qualified_name":"beta/notwitness"},{"qualified_name":"beta/old.witness","suspended":true},{"qualified_name":"bad/extra/foo.witness"}]}' >"$GC_AGENTS"
printf '%s\n' '{"sessions":[{"id":"s2","agent_name":"alpha/held.witness","closed":false},{"id":"s3","agent_name":"alpha/sleepheld.witness","closed":true}]}' >"$GC_SESSIONS"
printf '%s\n' '[{"id":"other","title":"other","ephemeral":true},{"id":"held","title":"mol-witness-patrol","ephemeral":true}]' >"$GC_HELD"
run_tick
[ "$RC" -ne 0 ] || fail 'assignment failure must fail overall'
grep -Fxq 'bd --rig alpha mol wisp mol-witness-patrol --root-only --var binding_prefix=fail. --json' "$GC_CALLS" || fail 'alpha prefix or rig'
grep -Fxq 'bd --rig alpha update wi-new --assignee=alpha/fail.witness' "$GC_CALLS" || fail 'assignment'
grep -Fxq 'bd --rig alpha mol burn wi-new --force' "$GC_CALLS" || fail 'failed assignment cleanup'
grep -Fxq 'bd --rig alpha list --assignee=alpha/held.witness --status=open,in_progress --type=molecule --include-infra --limit=0 --json' "$GC_CALLS" || fail 'held lookup'
grep -q '^session nudge s2 ' "$GC_CALLS" || fail 'held wisp nudge'
grep -Fq 'alpha/sleepheld.witness holds held, no live session; assignment carries the wake' "$tmp/out" || fail 'sleeping held witness'
grep -Fxq 'bd --rig beta mol wisp mol-witness-patrol --root-only --var binding_prefix= --json' "$GC_CALLS" || fail 'sleeping witness pour'
grep -Fxq 'bd --rig beta update wi-new --assignee=beta/witness' "$GC_CALLS" || fail 'continued after failure'
! grep -q '^session nudge s3 ' "$GC_CALLS" || fail 'closed session must not be nudged'
! grep -q 'notwitness\|old.witness\|bad/extra' "$GC_CALLS" || fail 'matched unrelated, suspended or malformed agent'
! grep ' update ' "$GC_CALLS" | grep -q -- '--status=' || fail 'assignment must leave wisp open'
[ "$(grep -c ' mol wisp ' "$GC_CALLS")" -eq 2 ] || fail 'held witness poured a wisp'

printf '%s\n' '{"agents":[{"qualified_name":"alpha/sleepheld.witness"}]}' >"$GC_AGENTS"
run_tick
[ "$RC" -eq 0 ] || fail 'held wisp without session must succeed'
! grep -q '^session nudge ' "$GC_CALLS" || fail 'sleeping held witness must not be nudged'
printf '%s\n' 'PASS: witness patrol tick'
