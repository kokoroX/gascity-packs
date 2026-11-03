#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-witness-patrol.toml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gc" <<'SH'
#!/bin/sh
case "$1 $2" in
  'session list') [ "${FAIL_SESSION:-0}" = 0 ] || exit 1; cat "$SESSIONS" ;;
  'bd list') [ "${FAIL_BD:-0}" = 0 ] || exit 1; cat "$BEADS" ;;
  'gastown witness-liveness-map') exec "$SCRIPT" ;;
  *) echo "unexpected gc invocation: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gc"
export PATH="$tmp/bin:$PATH" SESSIONS="$tmp/sessions" BEADS="$tmp/beads"
export GC_PACK_DIR="$ROOT/gastown"
script="${WITNESS_LIVENESS_MAP_SCRIPT:-$GC_PACK_DIR/assets/scripts/witness-liveness-map.sh}"
export SCRIPT="$script"
command="$GC_PACK_DIR/commands/witness-liveness-map/run.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$SESSIONS" <<'JSON'
{"sessions":[{"id":"id","name":"name","session_name":"session_name","alias":"alias","agent_name":"agent_name","state":"active"},{"id":"closed-id","state":"active","closed":true},{"id":"override","state":"active"}]}
JSON
cat >"$BEADS" <<'JSON'
[{"metadata":{"configured_named_identity":"configured","state":"asleep"}},{"status":"closed","metadata":{"configured_named_identity":"override","state":"active"}}]
JSON

# Test both the script and the pack command, including one physical JSON line.
for target in "$script" "$command"; do
  "$target" >"$tmp/out" 2>"$tmp/err" || fail "$target failed"
  [ "$(wc -l <"$tmp/out" | tr -d ' ')" = 1 ] || fail "stdout must be one line"
  jq -e -s 'length == 1 and (.[0] | .map_count == 8 and .session_count == 3 and
    ([.map.id, .map.name, .map.session_name, .map.alias, .map.agent_name] | all(. == "active")) and
    .map["closed-id"] == "closed" and .map.configured == "asleep" and .map.override == "closed")' "$tmp/out" >/dev/null || fail "incorrect map"
done

run_failure() {
  local expected="$1" rc
  shift
  rc=0
  "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected rc $expected, got $rc"
  [ -s "$tmp/err" ] || fail "missing diagnostic"
}

run_failure 1 env FAIL_SESSION=1 "$command"
jq -e '.map_count == 0 and .session_count == 0' "$tmp/out" >/dev/null || fail "session failure counts"
run_failure 1 env FAIL_BD=1 "$command"
jq -e '.map_count == 0 and .session_count == 0' "$tmp/out" >/dev/null || fail "bead failure counts"
printf '%s\n' '{"sessions":[{"state":"active"}]}' >"$SESSIONS"
printf '%s\n' '[]' >"$BEADS"
run_failure 1 "$command"
jq -e '.map == {} and .map_count == 0 and .session_count == 1' "$tmp/out" >/dev/null || fail "empty map counts"
printf '%s\n' '{invalid' >"$BEADS"
run_failure 1 "$command"
jq -e '.map_count == 0 and .session_count == 1' "$tmp/out" >/dev/null || fail "jq failure counts"
run_failure 2 env -u GC_PACK_DIR "$command"
[ ! -s "$tmp/out" ] || fail "missing context should not produce stdout"

# The formula wrapper must preserve the old failure classification: a failed
# query leaves both counts at 0 so the FAIL-SAFE message says "could not be
# built" rather than blaming an empty map.
wrapper="$tmp/wrapper.sh"
awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { inblk = 1; body = ""; next }
    inblk && /^[[:space:]]*```[[:space:]]*$/ {
        inblk = 0
        if (index(body, "build_liveness_map() {")) { printf "%s", body; found = 1 }
        body = ""
        next
    }
    inblk { body = body $0 "\n"; next }
    END { exit(found ? 0 : 1) }
' "$FORMULA" >"$wrapper" || fail "no fenced block contains build_liveness_map()"
bash -n "$wrapper" || fail "lifted wrapper does not parse"
printf '%s\n' '{"sessions":[{"id":"a","state":"active"},{"id":"b","state":"active"}]}' >"$SESSIONS"
printf '%s\n' '[]' >"$BEADS"
wrapper_result=$(
    set +eu
    export FAIL_BD=1
    . "$wrapper"
    build_liveness_map
    rc=$?
    printf '%s %s %s\n' "$rc" "$MAP_COUNT" "$SESSION_COUNT"
) || fail "wrapper subshell failed"
read -r wrapper_rc map_count session_count <<EOF
$wrapper_result
EOF
[ "$wrapper_rc" -ne 0 ] || fail "wrapper reported a usable map after a failed query"
[ "$map_count" = 0 ] || fail "wrapper kept a nonzero map count after a failed query"
[ "$session_count" = 0 ] || fail "wrapper kept a session count that would select the empty-map message"

echo "witness liveness map tests passed"
