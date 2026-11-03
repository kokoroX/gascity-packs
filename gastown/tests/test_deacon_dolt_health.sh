#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"
SCRIPT="${DEACON_DOLT_HEALTH_SCRIPT:-$GASTOWN/assets/scripts/deacon-dolt-health.sh}"
COMMAND="$GASTOWN/commands/deacon-dolt-health/run.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BIN="$tmp/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export GC_LOG="$tmp/gc.log"

cat >"$BIN/gc" <<'SH'
#!/bin/sh
printf 'gc %s\n' "$*" >>"$GC_LOG"
[ "$*" = "dolt health --json" ] || { echo "unexpected gc invocation: $*" >&2; exit 64; }
case "$STUB_HEALTH" in
missing-envelope)
    printf '%s\n' '{"schema_version":"1","ok":false,"error":{"code":"json_command_not_found","message":"command \"dolt health\" was not found","exit_code":1}}'
    exit 1 ;;
missing-text)
    printf 'gc: unknown command "dolt"\n\nRun "gc --help" for usage.\n' >&2
    exit 1 ;;
skipped)
    printf '%s\n' '{"skipped":{"reason":"bd-owned-proxied-scope","message":"bd owns it"}}'
    exit 0 ;;
not-applicable)
    printf '%s\n' '{"applicable":false,"reason":"city beads backend is mysql; no managed Dolt runtime to probe","server":{"running":false,"reachable":false}}'
    exit 0 ;;
port-missing|port-down)
    state="missing"
    [ "$STUB_HEALTH" = port-down ] && state="present but not running"
    {
        printf 'gc dolt: cannot resolve runtime port\n'
        printf '  state_file: /city/.gc/runtime/packs/dolt/dolt-state.json (%s)\n' "$state"
    } >&2
    exit 78 ;;
other-78)
    printf 'gc dolt: something else went wrong\n' >&2
    exit 78 ;;
store-error)
    printf 'Error: dolt: connection refused\nsecond line\n' >&2
    printf '%s\n' '{"schema_version":"1","ok":false,"error":{"code":"command_failed","message":"exit 1","exit_code":1}}'
    exit 1 ;;
garbage)
    printf 'panic: runtime error\n'
    exit 0 ;;
healthy)
    printf '%s\n' '{"timestamp":"2026-10-22T00:00:00Z","server":{"running":true,"reachable":true,"pid":4242,"port":3307,"latency_ms":3},"databases":[],"backups":{"dolt_stale":false},"processes":{"zombie_count":0,"zombie_pids":[]},"orphans":[]}'
    exit 0 ;;
*)
    echo "stub: unknown STUB_HEALTH=$STUB_HEALTH" >&2
    exit 64 ;;
esac
SH
chmod +x "$BIN/gc"

fail() { echo "FAIL: $*" >&2; exit 1; }

run_case() {
    local mode=$1 rc=0
    : >"$GC_LOG"
    STUB_HEALTH="$mode" "$SCRIPT" >"$tmp/out" 2>"$tmp/err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$mode: classification must exit 0, got $rc"
    [ "$(grep -c '^DOLT_HEALTH: ' "$tmp/out" || true)" -eq 1 ] ||
        fail "$mode: expected exactly one DOLT_HEALTH line"
}

assert_line() {
    local mode=$1 expected=$2
    grep -F -q "$expected" "$tmp/out" || fail "$mode: missing '$expected'"
}

expect_error() {
    local mode=$1 rc=$2 cause=$3
    run_case "$mode"
    assert_line "$mode" "DOLT_HEALTH: error ("
    assert_line "$mode" "DOLT_HEALTH_RC: $rc"
    assert_line "$mode" "DOLT_HEALTH_CAUSE: $cause"
    [ "$(grep -c '^DOLT_HEALTH_STDERR: ' "$tmp/out" || true)" -eq 1 ] ||
        fail "$mode: expected exactly one DOLT_HEALTH_STDERR line"
}

# The script itself must classify; it must never send mail.
run_case port-missing
assert_line port-missing "DOLT_HEALTH: not-applicable (no gc-managed Dolt runtime in this city; bd owns the server or none exists)"
if grep -q '^gc mail ' "$GC_LOG"; then
    fail "port-missing: the command must not send mail"
fi

run_case port-down
assert_line port-down "DOLT_HEALTH: outage (the gc-managed Dolt server is not running) -> CRITICAL row"

run_case missing-envelope
assert_line missing-envelope "DOLT_HEALTH: not-applicable (gc dolt health does not exist in this city; no Dolt pack)"
run_case missing-text
assert_line missing-text "DOLT_HEALTH: not-applicable (gc dolt health does not exist in this city; no Dolt pack)"

run_case skipped
assert_line skipped "DOLT_HEALTH: not-applicable (bd-owned-proxied-scope)"
run_case not-applicable
assert_line not-applicable "DOLT_HEALTH: not-applicable (city beads backend is mysql; no managed Dolt runtime to probe)"

expect_error store-error 1 "gc dolt health --json exited 1"
assert_line store-error "connection refused second line"

expect_error other-78 78 "gc dolt health --json exited 78"
expect_error garbage 0 "gc dolt health --json exited 0 without a JSON report"

run_case healthy
assert_line healthy "DOLT_HEALTH: evaluate"
tail -n 1 "$tmp/out" | jq -e '.server.reachable == true' >/dev/null ||
    fail "healthy: the report to evaluate was not printed after the verdict"

# The command adds pack context and forwards to the same script.
: >"$GC_LOG"
STUB_HEALTH=healthy GC_PACK_DIR="$GASTOWN" "$COMMAND" >"$tmp/out" 2>"$tmp/err" ||
    fail "the pack command failed for a usable report"
assert_line command "DOLT_HEALTH: evaluate"

# run.sh only adds pack context and forwards; missing context is exit 2.
rc=0
env -u GC_PACK_DIR "$COMMAND" >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] || fail "missing pack context must exit 2, got $rc"
[ ! -s "$tmp/out" ] || fail "missing pack context must not print a verdict"

echo "deacon dolt health tests passed"
