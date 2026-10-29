#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/deacon-patrol-tick.sh"
ORDER="$ROOT/gastown/orders/deacon-patrol-tick.toml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env sh
# Every invocation is logged so the tests can assert on the whole call set,
# not just on the script's stdout.
printf '%s\n' "$*" >>"$GC_CALLS"
case "$*" in
    "session list --json")
        cat "$GC_SESSIONS_JSON"
        ;;
    bd\ list\ *)
        case "$*" in
            *--status=in_progress*) cat "$GC_HELD_IN_PROGRESS" ;;
            *--status=open*) cat "$GC_HELD_OPEN" ;;
            *) printf '[]' ;;
        esac
        ;;
    bd\ mol\ wisp\ mol-deacon-patrol*)
        printf '{"new_epic_id":"%s"}\n' "${GC_NEW_WISP:-wi-new}"
        ;;
    bd\ update\ *)
        if [ -n "${GC_ASSIGN_FAIL:-}" ]; then
            exit 1
        fi
        ;;
    bd\ mol\ burn\ *)
        ;;
    session\ nudge\ *)
        shift
        shift
        for arg do
            case "$arg" in
                -*)
                    printf 'gc: unknown flag: %s\n' "$arg" >&2
                    exit 1
                    ;;
            esac
        done
        [ "$#" -ge 2 ] || {
            printf 'gc: session nudge requires an id and message\n' >&2
            exit 1
        }
        ;;
    *)
        printf 'unexpected gc invocation: %s\n' "$*" >&2
        exit 91
        ;;
esac
SH
    chmod +x "$bin/gc"
}

# run_tick [env assignments...] — SESSIONS/HELD_* files are re-read on every
# call, so tests only have to write the payloads they care about. RC is the
# script's exit status; OUT and ERR capture the two streams separately.
run_tick() {
    : >"$CALLS"
    set +e
    # ${1+"$@"} rather than "$@": bash 3.2 under `set -u` treats an empty "$@"
    # as an unbound variable.
    OUT=$(env GC_CITY="$CITY" GC_CALLS="$CALLS" GC_SESSIONS_JSON="$SESSIONS" \
        GC_HELD_IN_PROGRESS="$HELD_IN_PROGRESS" GC_HELD_OPEN="$HELD_OPEN" \
        GC_NEW_WISP="${NEW_WISP:-wi-new}" GC_ASSIGN_FAIL="${ASSIGN_FAIL:-}" \
        PATH="$BIN:$PATH" ${1+"$@"} bash "$SCRIPT" 2>"$ERRFILE")
    RC=$?
    set -e
    ERR=$(cat "$ERRFILE")
}

assert_nudge_shape() {
    grep -Eq '^session nudge ci-wisp-4co .+' "$CALLS" ||
        fail "the nudge must target the deacon session id and include a message: $(cat "$CALLS")"
    ! grep -q '^session nudge .*--message' "$CALLS" ||
        fail "the nudge must pass its message positionally: $(cat "$CALLS")"
}

# Session payloads use the envelope gc session list --json really prints.
set_payloads() {
    local sessions="$1" in_progress="$2" open="$3"
    printf '{"ok":true,"schema_version":1,"filters":{},"summary":{},"sessions":%s}' "$sessions" >"$SESSIONS"
    printf '%s' "$in_progress" >"$HELD_IN_PROGRESS"
    printf '%s' "$open" >"$HELD_OPEN"
}

DEACON_SESSION='[{"id":"ci-wisp-4co","template":"gastown.deacon","agent_name":"gastown.deacon","state":"active","closed":false}]'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
CITY="$tmp/city"
BIN="$tmp/bin"
SESSIONS="$tmp/sessions.json"
HELD_IN_PROGRESS="$tmp/held-in-progress.json"
HELD_OPEN="$tmp/held-open.json"
CALLS="$tmp/calls.txt"
ERRFILE="$tmp/stderr.txt"
mkdir -p "$CITY"
: >"$CITY/city.toml"
write_gc_stub "$BIN"

test_no_deacon_session_is_a_noop() {
    set_payloads '[]' '[]' '[]'
    run_tick

    [ "$RC" -eq 0 ] || fail "no deacon session must exit 0, got $RC ($ERR)"
    ! grep -q '^bd mol wisp' "$CALLS" ||
        fail "no deacon session must not pour a wisp: $(cat "$CALLS")"
    ! grep -q '^session nudge' "$CALLS" ||
        fail "no deacon session must not nudge: $(cat "$CALLS")"
    grep -q '^no deacon session$' <<<"$OUT" ||
        fail "no deacon session should say so, got: $OUT"

    # A closed deacon session is not a live target either.
    set_payloads '[{"id":"ci-wisp-4co","template":"gastown.deacon","agent_name":"gastown.deacon","state":"closed","closed":true}]' '[]' '[]'
    run_tick
    [ "$RC" -eq 0 ] || fail "a closed deacon session must exit 0, got $RC ($ERR)"
    ! grep -q '^bd mol wisp' "$CALLS" ||
        fail "a closed deacon session must not pour a wisp: $(cat "$CALLS")"
}

test_existing_wisp_is_only_nudged() {
    set_payloads "$DEACON_SESSION" '[{"id":"wi-held"}]' '[]'
    run_tick

    [ "$RC" -eq 0 ] || fail "an existing wisp must exit 0, got $RC ($ERR)"
    ! grep -q '^bd mol wisp' "$CALLS" ||
        fail "an existing wisp must not be duplicated: $(cat "$CALLS")"
    ! grep -q '^bd update' "$CALLS" ||
        fail "an existing wisp needs no assignment: $(cat "$CALLS")"
    [ "$(grep -c '^session nudge' "$CALLS")" -eq 1 ] ||
        fail "an existing wisp must produce exactly one nudge: $(cat "$CALLS")"
    assert_nudge_shape

    # An open wisp counts as held too — the order must not pour a second one.
    # A patrol wisp stays open for its whole life, so this is the common case.
    set_payloads "$DEACON_SESSION" '[]' '[{"id":"wi-queued"}]'
    run_tick
    [ "$RC" -eq 0 ] || fail "a queued wisp must exit 0, got $RC ($ERR)"
    ! grep -q '^bd mol wisp' "$CALLS" ||
        fail "a queued wisp must not be duplicated: $(cat "$CALLS")"
    [ "$(grep -c '^session nudge' "$CALLS")" -eq 1 ] ||
        fail "a queued wisp must still produce exactly one nudge: $(cat "$CALLS")"
    assert_nudge_shape
}

test_empty_hand_pours_assigns_and_nudges() {
    set_payloads "$DEACON_SESSION" '[]' '[]'
    run_tick

    [ "$RC" -eq 0 ] || fail "an empty hand must exit 0, got $RC ($ERR)"
    [ "$(grep -c '^bd mol wisp' "$CALLS")" -eq 1 ] ||
        fail "an empty hand must pour exactly one wisp: $(cat "$CALLS")"
    grep -F 'bd mol wisp mol-deacon-patrol --root-only --var binding_prefix=gastown. --json' "$CALLS" >/dev/null ||
        fail "the pour must carry the binding prefix as a var: $(cat "$CALLS")"
    grep -F 'bd update wi-new --assignee=gastown.deacon' "$CALLS" >/dev/null ||
        fail "the poured wisp must be assigned to the deacon agent name: $(cat "$CALLS")"
    [ "$(grep -c '^session nudge' "$CALLS")" -eq 1 ] ||
        fail "a fresh pour must produce exactly one nudge: $(cat "$CALLS")"
    assert_nudge_shape
    ! grep -q '^bd mol burn' "$CALLS" ||
        fail "a successful pour must not burn anything: $(cat "$CALLS")"
}

test_assign_failure_burns_the_poured_wisp_and_exits_nonzero() {
    set_payloads "$DEACON_SESSION" '[]' '[]'
    ASSIGN_FAIL=1 run_tick

    [ "$RC" -eq 1 ] || fail "an assign failure must exit 1, got $RC ($ERR)"
    [ "$(grep -c '^bd mol wisp' "$CALLS")" -eq 1 ] ||
        fail "the failure path must have poured exactly one wisp: $(cat "$CALLS")"
    grep -F 'bd mol burn wi-new --force' "$CALLS" >/dev/null ||
        fail "an unassignable wisp must be reclaimed by id: $(cat "$CALLS")"
    ! grep -q '^session nudge' "$CALLS" ||
        fail "an assign failure must not nudge: $(cat "$CALLS")"
}

test_order_owns_the_cadence() {
    # The script is only useful if the order actually fires it on a cooldown.
    [[ -f "$ORDER" ]] || fail "missing gastown/orders/deacon-patrol-tick.toml"
    grep -F 'trigger = "cooldown"' "$ORDER" >/dev/null ||
        fail "deacon-patrol-tick must be a cooldown order"
    grep -F 'interval = "15m"' "$ORDER" >/dev/null ||
        fail "deacon-patrol-tick must own the deacon's 15m cadence"
    grep -F 'exec = "bash $GC_PACK_DIR/assets/scripts/deacon-patrol-tick.sh"' "$ORDER" >/dev/null ||
        fail "the order must exec the pack-local script"
    # The order runs the script through `bash`, so the exec bit is not
    # load-bearing; the file still has to be there.
    [[ -f "$SCRIPT" ]] || fail "missing gastown/assets/scripts/deacon-patrol-tick.sh"
}

test_no_deacon_session_is_a_noop
test_existing_wisp_is_only_nudged
test_empty_hand_pours_assigns_and_nudges
test_assign_failure_burns_the_poured_wisp_and_exits_nonzero
test_order_owns_the_cadence

echo "deacon patrol tick tests passed"
