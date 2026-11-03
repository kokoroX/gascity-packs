#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"
SCRIPT="${SHUTDOWN_PROGRESS_PROBE_SCRIPT:-$GASTOWN/assets/scripts/shutdown-progress-probe.sh}"
COMMAND="$GASTOWN/commands/shutdown-progress-probe/run.sh"
FORMULA="$GASTOWN/formulas/mol-shutdown-dance.toml"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
BIN="$tmp/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
export GC_LOG="$tmp/gc.log"
export SESSIONS="$tmp/sessions.json"
export BEADS="$tmp/beads.json"
export BEAD_JSON="$tmp/bead.json"

cat >"$BIN/gc" <<'SH'
#!/bin/sh
printf 'gc %s\n' "$*" >>"$GC_LOG"
if [ "$1 $2" = "gastown shutdown-progress-probe" ]; then
    [ "${FAIL_PROBE:-0}" = 0 ] || exit 1
    GC_PACK_DIR="$PACK" exec "$PACK/commands/shutdown-progress-probe/run.sh" "$3"
fi
case "$1 $2" in
    "session list") cat "$SESSIONS" ;;
    "bd --rig")
        case "$4" in
            list) cat "$BEADS" ;;
            show) cat "$BEAD_JSON" ;;
            *) echo "unexpected bd --rig subcommand: $4" >&2; exit 64 ;;
        esac
        ;;
    "bd show") cat "$BEAD_JSON" ;;
    *) echo "unexpected gc invocation: $*" >&2; exit 64 ;;
esac
SH
chmod +x "$BIN/gc"
export PACK="$GASTOWN"

fail() { echo "FAIL: $*" >&2; exit 1; }

printf '%s\n' '{"sessions":[]}' >"$SESSIONS"
printf '%s\n' '[]' >"$BEADS"
printf '%s\n' '[]' >"$BEAD_JSON"

# The command and the script are both entry points; every leg runs the
# command, which execs the configured script.
target="demo/gastown.worker"
export target
export GC_CITY_PATH="$tmp/city"
mkdir -p "$tmp/city"

run_probe() {
    local expected_rc=$1 rc=0
    shift
    : >"$GC_LOG"
    "$SCRIPT" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    [ "$rc" -eq "$expected_rc" ] || fail "expected rc $expected_rc, got $rc"
}

assert_signal() {
    local expected=$1 last
    last=$(tail -n 1 "$tmp/out")
    [ "$last" = "progress_signal=$expected" ] ||
        fail "expected progress_signal=$expected, got: $last"
}

run_probe 2
[ -s "$tmp/err" ] || fail "missing target must diagnose on stderr"
[ ! -s "$tmp/out" ] || fail "missing target must not print a signal"

# No matching session at all is inconclusive, never idle.
run_probe 0 "$target"
assert_signal unknown

# More than one exact match is ambiguous; do not query an arbitrary bead store.
printf '%s\n' '{"sessions":[{"id":"s1","name":"demo/gastown.worker","rig":"demo"},{"id":"s2","alias":"demo/gastown.worker","rig":"demo"}]}' >"$SESSIONS"
run_probe 0 "$target"
assert_signal unknown
if grep -q '^gc bd ' "$GC_LOG"; then
    fail "ambiguous target-session lookup queried an arbitrary bead store"
fi

# One session with no claimed work is a real "none".
printf '%s\n' '{"sessions":[{"id":"session-1","name":"demo/gastown.worker","rig":"demo","work_dir":"/missing/provider"}]}' >"$SESSIONS"
printf '%s\n' '[]' >"$BEADS"
run_probe 0 "$target"
assert_signal none
grep -q '^gc bd --rig demo list --status=in_progress --json --limit=0$' "$GC_LOG" ||
    fail "the work query was not routed to the target rig store"

# A bead updated inside the 7-minute window means progress.
recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' '[{"id":"bead-1","assignee":"session-1","updated_at":"'"$recent"'"}]' >"$BEADS"
printf '%s\n' '[{"id":"bead-1","updated_at":"'"$recent"'","metadata":{}}]' >"$BEAD_JSON"
run_probe 0 "$target"
assert_signal bead
grep -q '^target_bead=bead-1 ' "$tmp/err" ||
    fail "bead diagnostics must go to stderr, not stdout"

# A recent file in the validated per-bead worktree means progress too.
city="$GC_CITY_PATH"
provider="$city/.gc/worktrees/demo/polecats/worker"
artifact="$city/.gc/worktrees/demo/artifacts/worktrees/bead-1"
mkdir -p "$(dirname "$provider")" "$(dirname "$artifact")"
git init -q "$provider"
git -C "$provider" config user.email test@example.com
git -C "$provider" config user.name test
printf 'seed\n' >"$provider/seed.txt"
git -C "$provider" add seed.txt
git -C "$provider" commit -qm seed
git -C "$provider" worktree add -q "$artifact" -b bead-1
printf 'recent\n' >"$artifact/recent.txt"
printf '%s\n' '{"sessions":[{"id":"session-1","name":"demo/gastown.worker","rig":"demo","work_dir":"'"$provider"'"}]}' >"$SESSIONS"
old="2020-01-01T00:00:00Z"
printf '%s\n' '[{"id":"bead-1","assignee":"session-1","updated_at":"'"$old"'"}]' >"$BEADS"
printf '%s\n' '[{"id":"bead-1","updated_at":"'"$old"'","metadata":{"artifact_dir":"'"$artifact"'"}}]' >"$BEAD_JSON"
run_probe 0 "$target"
case "$(tail -n 1 "$tmp/out")" in
    "progress_signal=worktree:$artifact/"*) ;;
    *) fail "expected a worktree signal under $artifact, got: $(tail -n 1 "$tmp/out")" ;;
esac

# The formula wrapper must never promote a failed command to "none".
wrapper="$tmp/wrapper.sh"
python3 - "$FORMULA" "$wrapper" <<'PY'
import pathlib
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    steps = tomllib.load(handle)["steps"]
description = next(s for s in steps if s["id"] == "execute")["description"]
begin = description.index("# BEGIN SHUTDOWN_PROGRESS_PROBE")
end = description.index("# END SHUTDOWN_PROGRESS_PROBE", begin)
body = description[begin:end].splitlines()[1:]
pathlib.Path(sys.argv[2]).write_text("\n".join(body) + "\n", encoding="utf-8")
PY
bash -n "$wrapper" || fail "the shutdown progress wrapper does not parse"
(
    set +eu
    export FAIL_PROBE=1
    # shellcheck source=/dev/null
    . "$wrapper"
) >"$tmp/out" 2>"$tmp/err"
grep -q '^progress_signal=unknown$' "$tmp/out" ||
    fail "a failed progress command must fall back to unknown (pardon, do not kill)"

# An agent's shell may run the step under `set -e -o pipefail`; a failed probe
# must neither abort the step nor skip the unknown fallback: a target is
# pardoned, not killed, and an aborted step never reaches the pardon branch. The
# block runs in a child shell because errexit is suppressed inside a subshell
# that sits on the left of `||` -- a check that looks green there proves nothing.
cat >"$tmp/eager.sh" <<'SH'
set -euo pipefail
# shellcheck source=/dev/null
. "$1"
SH
rc=0
env FAIL_PROBE=1 bash "$tmp/eager.sh" "$wrapper" >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 0 ] || fail "a failed progress command must not abort the step under set -e (rc=$rc)"
grep -q '^progress_signal=unknown$' "$tmp/out" ||
    fail "a failed progress command under set -e must still report unknown, got: $(cat "$tmp/out")"

# The command adds pack context and forwards to the same script.
printf '%s\n' '{"sessions":[{"id":"session-1","name":"demo/gastown.worker","rig":"demo"}]}' >"$SESSIONS"
printf '%s\n' '[]' >"$BEADS"
GC_PACK_DIR="$GASTOWN" "$COMMAND" "$target" >"$tmp/out" 2>"$tmp/err" ||
    fail "the pack command failed for a valid target"
assert_signal none

# Missing pack context is a usage error from the command, not a signal.
rc=0
env -u GC_PACK_DIR "$COMMAND" "$target" >"$tmp/out" 2>"$tmp/err" || rc=$?
[ "$rc" -eq 2 ] || fail "missing pack context must exit 2, got $rc"
[ ! -s "$tmp/out" ] || fail "missing pack context must not print a signal"

echo "shutdown progress probe tests passed"
