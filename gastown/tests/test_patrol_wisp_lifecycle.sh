#!/usr/bin/env bash
set -euo pipefail

# Executed coverage for the refinery and deacon patrol-wisp lifecycle
# (gastownhall/gascity#5502).
#
# A patrol wisp is a root-only ephemeral molecule that stays `open` for its
# whole life: assigning it does not move it to `in_progress`, and only
# `gc bd mol burn` ends it. `$GC_BEAD_ID` is not set in a patrol session, so
# the fallback query is what names the current wisp. Two defects leaked one
# wisp per patrol cycle:
#
#   - the status half: the fallback asked for `--status=in_progress`, which
#     never matches a patrol wisp, so the current wisp was never resolved;
#   - pour-before-resolve: every exit path poured and assigned the successor
#     FIRST and only then noticed it could not name the current wisp, drained,
#     and left both behind.
#
# Startup had the same leak by another route: it poured a fresh wisp on every
# start without looking for the one already assigned.
#
# The deacon's cadence is now owned by the `deacon-patrol-tick` order, so its
# loop has one more property pinned here: a rotation burns the current wisp and
# ends the turn, requesting a restart only on failure, never pouring a successor
# and never draining. A self-poured successor changes the fresh session's assigned work
# every cycle, which is the hot loop this design exists to stop. Startup adopts
# the wisp the order assigned and prints IDLE when there is none; an empty hand
# is the gap between ticks, not a license to self-pour. And an empty GC_AGENT
# must never reach a lookup: an empty --assignee is no filter, so it would hand
# back every patrol wisp in the store, other agents' and other cities' included.
#
# Every block here is LIFTED out of the shipped formula or prompt and executed
# against a stateful stub `gc`, not transcribed. The stub keeps a tiny wisp
# ledger and behaves like the beads CLI where it matters: `gc bd list` hides
# the wisps tier unless `--include-infra` is passed, `gc bd mol wisp` pours an
# unassigned open root, and `gc bd mol burn` deletes. Point PATROL_WISP_ROOT at another tree to run
# this file byte-unmodified against it (the red control).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TREE="${PATROL_WISP_ROOT:-$ROOT}"
GASTOWN="$TREE/gastown"

command -v jq >/dev/null 2>&1 || {
    echo "FAIL: jq required (the lifted blocks parse the stub's JSON with real jq)" >&2
    exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

BIN="$tmp/bin"
REGIONS="$tmp/regions"
STATE="$tmp/state.tsv"
SEQ="$tmp/seq"
GC_LOG="$tmp/gc.log"
LAST_OUT="/dev/null"
RC=0
export GC_LOG STATE SEQ

fail() {
    echo "FAIL: $*" >&2
    if [ -s "$LAST_OUT" ]; then
        echo "--- captured block output ---" >&2
        tail -n 20 "$LAST_OUT" >&2
    fi
    if [ -s "$GC_LOG" ]; then
        echo "--- gc calls ---" >&2
        tail -n 20 "$GC_LOG" >&2
    fi
    exit 1
}

# ---------------------------------------------------------------------------
# Stub gc: a TSV wisp ledger (id, title, status, assignee, ephemeral, seq).
# ---------------------------------------------------------------------------

write_gc_stub() {
    mkdir -p "$BIN"
    cat >"$BIN/gc" <<'SH'
#!/usr/bin/env bash
# Patterns are written so they read as `gc bd ...`, which is what
# tests/test_no_bare_bd_commands.py accepts.
invocation="gc $*"
printf '%s\n' "$invocation" >>"$GC_LOG"
row_json() {
    jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t")) |
      map({id: .[0], title: .[1], status: .[2], assignee: .[3],
           issue_type: "molecule", ephemeral: (.[4] == "true"),
           created_at: ((.[5] | tonumber) + 1792627200 | todate)})'
}
case "$invocation" in
"gc bd list "*)
    if [ "${STUB_LIST_FAIL:-0}" = 1 ]; then
        echo "Error: database unavailable (stub)" >&2
        exit 1
    fi
    assignee="" statuses="" type="" infra=0 limit=50
    for arg in "${@:3}"; do
        case "$arg" in
            --assignee=*) assignee=${arg#--assignee=} ;;
            --status=*) statuses=${arg#--status=} ;;
            --type=*) type=${arg#--type=} ;;
            --include-infra) infra=1 ;;
            --limit=*) limit=${arg#--limit=} ;;
        esac
    done
    # bd skips the wisps tier on any list without --include-infra. gc >= 1.5.0
    # appends the flag itself to a --type=molecule list; STUB_GC_APPENDS_INFRA
    # selects that behavior, so each leg runs against both.
    if [ "$type" = molecule ] && [ "$infra" != 1 ] && [ "${STUB_GC_APPENDS_INFRA:-0}" != 1 ]; then
        printf '[]\n'
        exit 0
    fi
    # Like bd, an empty --assignee is no filter at all.
    awk -F '\t' -v a="$assignee" -v s=",$statuses," '
        (a == "" || $4 == a) && (s == ",," || index(s, "," $3 ",")) { print }
    ' "$STATE" | sort -t "$(printf '\t')" -k6,6nr |
        { if [ "$limit" = 0 ]; then cat; else head -n "$limit"; fi; } | row_json
    ;;
"gc bd mol "*)
    case "$3" in
    wisp)
        if [ "${STUB_POUR_FAIL:-0}" = 1 ]; then
            echo "Error: pour failed (stub)" >&2
            exit 1
        fi
        n=$(( $(cat "$SEQ") + 1 ))
        printf '%s\n' "$n" >"$SEQ"
        printf 'wisp-%s\t%s\topen\t\ttrue\t%s\n' "$n" "$4" "$n" >>"$STATE"
        printf '{"new_epic_id":"wisp-%s"}\n' "$n"
        ;;
    burn)
        if [ "${STUB_BURN_FAIL:-0}" = 1 ]; then
            echo "error: dolt: connection reset by peer (stub)" >&2
            exit 1
        fi
        if ! awk -F '\t' -v id="$4" '$1 == id { found = 1 } END { exit !found }' "$STATE"; then
            echo "Error: no issue found matching \"$4\"" >&2
            exit 1
        fi
        awk -F '\t' -v id="$4" '$1 != id' "$STATE" >"$STATE.new" && mv -f "$STATE.new" "$STATE"
        echo "Burned wisp: $4"
        ;;
    *) printf '{}\n' ;;
    esac
    ;;
"gc bd update "*)
    id=$3 assignee="" has_assignee=0
    for arg in "${@:4}"; do
        case "$arg" in --assignee=*) assignee=${arg#--assignee=}; has_assignee=1 ;; esac
    done
    if [ "${STUB_ASSIGN_FAIL:-0}" = 1 ]; then
        echo "Error: update failed (stub)" >&2
        exit 1
    fi
    awk -F '\t' -v id="$id" '$1 == id { found = 1 } END { exit !found }' "$STATE" || {
        echo "Error: no issue found matching \"$id\"" >&2
        exit 1
    }
    if [ "$has_assignee" = 1 ]; then
        awk -F '\t' -v OFS='\t' -v id="$id" -v a="$assignee" '$1 == id { $4 = a } { print }' \
            "$STATE" >"$STATE.new" && mv -f "$STATE.new" "$STATE"
    fi
    ;;
*) printf '{}\n' ;;
esac
SH
    chmod +x "$BIN/gc"
}

# seed_state <row>... where row is "id title status assignee ephemeral seq".
seed_state() {
    : >"$STATE"
    printf '100\n' >"$SEQ"
    local row
    for row in "$@"; do
        # shellcheck disable=SC2086
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' $row >>"$STATE"
    done
}

ids_where() {  # ids_where <title> <assignee>
    awk -F '\t' -v t="$1" -v a="$2" '$2 == t && $4 == a { print $1 }' "$STATE" | sort
}

has_id() { awk -F '\t' -v id="$1" '$1 == id { found = 1 } END { exit !found }' "$STATE"; }

count_calls() { grep -c -F -- "$1" "$GC_LOG" || true; }

# ---------------------------------------------------------------------------
# Lifting.
# ---------------------------------------------------------------------------

# lift <file> <dir>: write every patrol-wisp lifecycle region in <file> to
# <dir>/rotate-N.sh and every startup reconcile region to <dir>/startup-N.sh.
# Formulas are read through tomllib, so TOML string escapes are decoded exactly
# as gc decodes them before an agent ever sees the text.
#
# A rotate region starts at the wisp resolution and ends at the burn of the
# resolved wisp (plus the `gc runtime request-restart` that follows it when the
# block ends an order-paced cycle); both ends must sit in ONE fenced block,
# because that is the script an agent runs. A burn in a different block from its
# resolution reads a variable that no longer exists, so a split fails extraction
# here.
lift() {
    python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys
import tomllib

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
if src.suffix == ".toml":
    doc = tomllib.loads(src.read_text())
    texts = [doc.get("description", "")] + [s.get("description", "") for s in doc.get("steps", [])]
else:
    texts = [src.read_text()]

subs = {
    "{{target_branch}}": "main", "{{rig_name}}": "testrig", "{{binding_prefix}}": "",
    "{{ .DefaultBranch }}": "main", "{{ .RigName }}": "testrig", "{{ .BindingPrefix }}": "",
}

def fences(text):
    block, inside = [], False
    for line in text.split("\n"):
        if line.strip().startswith("```"):
            if inside:
                yield block
                block, inside = [], False
            elif line.strip() == "```bash":
                inside = True
            continue
        if inside:
            block.append(line)

def dedent(lines):
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    body = "\n".join(l[indent:] for l in lines) + "\n"
    for hole, value in subs.items():
        body = body.replace(hole, value)
    if "{{" in body:
        sys.exit(f"unsubstituted template hole in a lifted block of {src}")
    return body

def close_ifs(block, start, end):
    # Close every `if` the region opened, so a burn nested in an if/else (or
    # written as the condition of one) and a startup whose report sits inside
    # its idle/work branch both lift whole.
    depth = 0
    for j in range(start, len(block)):
        word = block[j].strip()
        if word.startswith("if "):
            depth += 1
        elif word == "fi":
            depth -= 1
        if j >= end and depth == 0:
            return j
    return end

rotate = startup = 0
for text in texts:
    for block in fences(text):
        i = 0
        while i < len(block):
            line = block[i].strip()
            if line.startswith("CURRENT_WISP=${GC_BEAD_ID"):
                start = i
                # The prompt fallback reads its list once, above the resolution,
                # and the deacon formula refuses an empty identity above it.
                for k in range(i - 1, -1, -1):
                    above = block[k].strip()
                    if above.startswith("PATROL_WISPS_JSON=$(gc bd list") or \
                            above.startswith('if [ -z "${GC_AGENT:-}" ]; then'):
                        start = k
                end = next((j for j in range(i, len(block))
                            if 'gc bd mol burn "$CURRENT_WISP" --force' in block[j]), None)
                if end is None:
                    sys.exit(f"{src}: a wisp resolution has no burn of $CURRENT_WISP in the same fenced block")
                end = close_ifs(block, start, end)
                # An order-paced cycle ends by requesting a restart: keep it in
                # the region so the legs can assert the cycle's true last call.
                nxt = end + 1
                while nxt < len(block) and not block[nxt].strip():
                    nxt += 1
                if nxt < len(block) and block[nxt].strip() == "gc runtime request-restart":
                    end = nxt
                rotate += 1
                (out / f"rotate-{rotate}.sh").write_text(dedent(block[start : end + 1]))
                i = end + 1
                continue
            if line.startswith("PATROL_WISPS_JSON=$(gc bd list") and any(
                    'echo "Patrol wisp: $WISP"' in b for b in block[i:]):
                end = next(j for j in range(i, len(block)) if 'echo "Patrol wisp: $WISP"' in block[j])
                end = close_ifs(block, i, end)
                startup += 1
                (out / f"startup-{startup}.sh").write_text(dedent(block[i : end + 1]))
                i = end + 1
                continue
            i += 1
print(rotate, startup)
PY
}

# run_region <script> [VAR=value...]: execute a lifted region as one unit, in
# a plain `set +eu` shell like the agent's, with the stub first on PATH.
run_region() {
    local script="$1"
    shift
    RC=0
    LAST_OUT="$tmp/last.out"
    : >"$GC_LOG"
    (
        cd "$tmp" || exit 99
        env -u GC_BEAD_ID -u GC_TRIGGER_WORK_BEAD_ID \
            PATH="$BIN:$PATH" GC_LOG="$GC_LOG" STATE="$STATE" SEQ="$SEQ" \
            STUB_GC_APPENDS_INFRA="$GC_APPENDS_INFRA" GC_AGENT="$AGENT" "$@" \
            bash -c 'set +eu; . "$1"' bash "$script"
    ) >"$LAST_OUT" 2>&1 || RC=$?
}

# ---------------------------------------------------------------------------
# Legs for a rotate region (resolve -> pour -> assign -> burn).
# ---------------------------------------------------------------------------

# drained: was `gc runtime drain-ack` called in the last region run?
drained() { grep -q '^gc runtime drain-ack' "$GC_LOG"; }

# $1 = region, $2 = label, $3 = "strict" (an unnameable wisp pours nothing) or
# "bootstrap" (a list that reads empty may pour the first wisp), $4 = options:
#   drain        every failure exit drains the session before exiting
#   burn-drains  a failed burn of the current wisp drains and exits non-zero
#   id-guard     an explicit GC_BEAD_ID with an empty GC_AGENT still refuses
rotate_legs() {
    local region="$1" label="$2" mode="$3" opts=",$4," left

    must_drain() {  # must_drain <what>: the failure exit drained, if this region drains
        case "$opts" in
            *,drain,*) drained || fail "$label: $1 must drain the session (gc runtime drain-ack), not only end the turn" ;;
        esac
    }

    # The #5502 regression: an open patrol wisp, no GC_BEAD_ID.
    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: rotating an open current wisp must succeed (rc=$RC)"
    has_id w-cur && fail "$label: the open current wisp was not resolved and burned (status half / --include-infra)"
    left=$(ids_where "$FORMULA" "$AGENT")
    [ "$(printf '%s\n' "$left" | grep -c .)" -eq 1 ] ||
        fail "$label: expected exactly one assigned patrol wisp after rotating, found: $left"
    [ "$(count_calls 'gc bd mol wisp')" -eq 1 ] || fail "$label: expected exactly one pour"
    drained && fail "$label: a successful rotation must not drain the session"

    # Status half, other side: an in_progress wisp is the current wisp too.
    seed_state "w-cur $FORMULA in_progress $AGENT true 1"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: rotating an in_progress current wisp must succeed (rc=$RC)"
    has_id w-cur && fail "$label: an in_progress current wisp was not burned"

    # Missing identity: nothing assigned, nothing to name.
    seed_state
    run_region "$region"
    if [ "$mode" = strict ]; then
        [ "$RC" -ne 0 ] || fail "$label: an unnameable current wisp must stop the path"
        [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] ||
            fail "$label: poured a successor without naming the current wisp (resolve-before-pour)"
        [ ! -s "$STATE" ] || fail "$label: the ledger changed although nothing could be named"
        must_drain "an unnameable current wisp"
    else
        [ "$RC" -eq 0 ] || fail "$label: a list that reads empty must bootstrap one wisp (rc=$RC)"
        [ "$(ids_where "$FORMULA" "$AGENT" | grep -c .)" -eq 1 ] ||
            fail "$label: a list that reads empty must leave exactly one assigned patrol wisp"
    fi

    # A failed list is not an empty list.
    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region" STUB_LIST_FAIL=1
    [ "$RC" -ne 0 ] || fail "$label: a failed wisp query must stop the path"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured a successor after a failed wisp query"
    has_id w-cur || fail "$label: burned the current wisp after a failed wisp query"
    must_drain "a failed wisp query"

    # An explicit GC_BEAD_ID names the wisp; the query is not consulted.
    seed_state "w-old $FORMULA open $AGENT true 1" "w-cur $FORMULA open $AGENT true 2"
    run_region "$region" GC_BEAD_ID=w-old
    [ "$RC" -eq 0 ] || fail "$label: rotating the GC_BEAD_ID wisp must succeed (rc=$RC)"
    has_id w-old && fail "$label: GC_BEAD_ID named the current wisp but it was not the one burned"
    has_id w-cur || fail "$label: burned a wisp GC_BEAD_ID did not name"

    # Pour failure: nothing burned.
    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region" STUB_POUR_FAIL=1
    [ "$RC" -ne 0 ] || fail "$label: a failed pour must stop the path"
    has_id w-cur || fail "$label: burned the current wisp although no successor was poured"
    must_drain "a failed pour"

    # Assignment failure: the unassigned successor is reclaimed, the current kept.
    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region" STUB_ASSIGN_FAIL=1
    [ "$RC" -ne 0 ] || fail "$label: a failed assignment must stop the path"
    has_id w-cur || fail "$label: burned the current wisp although its successor was never assigned"
    [ "$(awk -F '\t' '$4 == ""' "$STATE" | grep -c .)" -eq 0 ] ||
        fail "$label: left an unassigned successor behind; no assignee-scoped query can ever find it"
    must_drain "a failed assignment"

    # A failed burn of the current wisp: the successor is assigned, the current
    # is still open. Ending the turn there is the deacon's last turn; draining
    # gets a restarted session whose startup reconciles the pair.
    case "$opts" in
    *,burn-drains,*)
        seed_state "w-cur $FORMULA open $AGENT true 1"
        run_region "$region" STUB_BURN_FAIL=1
        [ "$RC" -ne 0 ] || fail "$label: a failed burn of the current wisp must stop the path"
        drained || fail "$label: a failed burn of the current wisp must drain the session"
        [ "$(ids_where "$FORMULA" "$AGENT" | grep -c .)" -eq 2 ] ||
            fail "$label: after a failed burn the current wisp and its assigned successor should both remain for the restarted session to reconcile"
        ;;
    esac

    # An empty identity reaches no lookup: an empty --assignee is no filter.
    seed_state "w-mine $FORMULA open $AGENT true 1" "w-theirs $FORMULA open other-city/agent true 2"
    run_region "$region" GC_AGENT=
    [ "$RC" -ne 0 ] || fail "$label: an empty GC_AGENT must stop the path"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured a successor with an empty GC_AGENT"
    has_id w-mine || fail "$label: burned a patrol wisp with an empty GC_AGENT"
    has_id w-theirs || fail "$label: burned another agent's patrol wisp with an empty GC_AGENT"
    must_drain "an empty GC_AGENT"
    case "$opts" in
    *,id-guard,*)
        seed_state "w-mine $FORMULA open $AGENT true 1" "w-theirs $FORMULA open other-city/agent true 2"
        run_region "$region" GC_AGENT= GC_BEAD_ID=w-mine
        [ "$RC" -ne 0 ] || fail "$label: an explicit wisp id with an empty GC_AGENT must stop the path"
        [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured a successor nobody would own"
        has_id w-mine || fail "$label: burned the current wisp with no identity to hand its successor to"
        drained || fail "$label: an empty GC_AGENT must drain the session"
        ;;
    esac

    # Duplicates: the newest is the current wisp.
    seed_state "w-old $FORMULA open $AGENT true 1" "w-new $FORMULA open $AGENT true 2"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: rotating among duplicates must succeed (rc=$RC)"
    has_id w-new && fail "$label: the newest patrol wisp must be the one resolved and burned"
    return 0
}

# ---------------------------------------------------------------------------
# Legs for a deacon rotate region (resolve -> burn -> end turn or restart).
#
# The `deacon-patrol-tick` order owns the deacon's cadence, so a rotation never
# pours and never drains: it burns the wisp and ends the turn, requesting a
# restart on failure. A self-poured successor would change the fresh
# session's assigned work every cycle; a drain would restart without the wisp
# being burned. Either one restores the hot loop this design exists to stop.
# ---------------------------------------------------------------------------

restart_requested() {
    [ -n "$(tail -n 1 "$GC_LOG" 2>/dev/null)" ] &&
        [ "$(tail -n 1 "$GC_LOG")" = "gc runtime request-restart" ]
}

deacon_rotate_legs() {
    local region="$1" label="$2"

    # The usual case: one open patrol wisp assigned, no GC_BEAD_ID.
    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: burning the current open wisp must succeed (rc=$RC)"
    has_id w-cur && fail "$label: the open current wisp was not resolved and burned (status half / --include-infra)"
    [ ! -s "$STATE" ] || fail "$label: a wisp-owning cycle must not pour a successor: $(cat "$STATE")"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured a successor; the order owns the pour"
    drained && fail "$label: a successful rotation must not drain the session"
    ! grep -q '^gc runtime request-restart$' "$GC_LOG" || fail "$label: a successful burn must end the turn without a restart"
    grep -F -q 'Patrol cycle done: burned w-cur; ending turn until the next tick.' "$LAST_OUT" || fail "$label: successful burn must report the end of the turn"

    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region" STUB_BURN_FAIL=1
    has_id w-cur || fail "$label: a failed burn must leave the wisp assigned"
    restart_requested || fail "$label: a failed burn must request a restart"
    drained && fail "$label: a failed burn must not drain"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: a failed burn must not pour"

    # Status half, other side: an in_progress wisp is the current wisp too.
    seed_state "w-cur $FORMULA in_progress $AGENT true 1"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: burning an in_progress current wisp must succeed (rc=$RC)"
    has_id w-cur && fail "$label: an in_progress current wisp was not burned"
    ! grep -q '^gc runtime request-restart$' "$GC_LOG" || fail "$label: an in_progress burn must end the turn"

    # No assigned wisp: burn nothing, pour nothing, and still request a restart.
    seed_state
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: a cycle with no current wisp must end cleanly (rc=$RC)"
    [ ! -s "$STATE" ] || fail "$label: poured a wisp with none assigned"
    grep -F -q 'Could not resolve current deacon wisp; not burning.' "$LAST_OUT" ||
        fail "$label: an empty hand must say it did not burn"
    restart_requested || fail "$label: an empty hand must still request a restart"

    # A failed list is not "no wisp": nothing is burned, nothing is poured.
    seed_state "w-cur $FORMULA open $AGENT true 1"
    run_region "$region" STUB_LIST_FAIL=1
    has_id w-cur || fail "$label: burned the current wisp after a failed wisp query"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured after a failed wisp query"
    restart_requested || fail "$label: a failed wisp query must still request a restart"

    # An explicit GC_BEAD_ID names the wisp; the query is not consulted.
    seed_state "w-old $FORMULA open $AGENT true 1" "w-cur $FORMULA open $AGENT true 2"
    run_region "$region" GC_BEAD_ID=w-old
    [ "$RC" -eq 0 ] || fail "$label: burning the GC_BEAD_ID wisp must succeed (rc=$RC)"
    has_id w-old && fail "$label: GC_BEAD_ID named the current wisp but it was not burned"
    has_id w-cur || fail "$label: burned a wisp GC_BEAD_ID did not name"
    ! grep -q '^gc runtime request-restart$' "$GC_LOG" || fail "$label: a named burn must end the turn"

    # An empty identity reaches no lookup: an empty --assignee is no filter.
    seed_state "w-mine $FORMULA open $AGENT true 1" "w-theirs $FORMULA open other-city/agent true 2"
    run_region "$region" GC_AGENT=
    has_id w-mine || fail "$label: burned a patrol wisp with an empty GC_AGENT"
    has_id w-theirs || fail "$label: burned another agent's patrol wisp with an empty GC_AGENT"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured with an empty GC_AGENT"
    restart_requested || fail "$label: an empty GC_AGENT must still request a restart"

    # Duplicates: the newest is the current wisp.
    seed_state "w-old $FORMULA open $AGENT true 1" "w-new $FORMULA open $AGENT true 2"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: rotating among duplicates must succeed (rc=$RC)"
    has_id w-new && fail "$label: the newest patrol wisp must be the one resolved and burned"
    ! grep -q '^gc runtime request-restart$' "$GC_LOG" || fail "$label: a duplicate burn must end the turn"
    return 0
}

# ---------------------------------------------------------------------------
# Legs for the deacon startup reconcile region. It adopts the wisp the order
# assigned and never pours: an empty hand is the gap between ticks, printed as
# IDLE, not a license to self-pour.
# ---------------------------------------------------------------------------

deacon_startup_legs() {
    local region="$1" label="$2"

    # Leaked surplus: keep the newest, burn the rest, pour nothing.
    seed_state "w-1 $FORMULA open $AGENT true 1" "w-2 $FORMULA open $AGENT true 2" \
        "w-3 $FORMULA open $AGENT true 3" "f-other mol-other-patrol open $AGENT true 4" \
        "w-elsewhere $FORMULA open someone-else true 5"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: reconciling leaked wisps must succeed (rc=$RC)"
    [ "$(ids_where "$FORMULA" "$AGENT")" = "w-3" ] ||
        fail "$label: expected only the newest wisp w-3 to survive, found: $(ids_where "$FORMULA" "$AGENT" | tr '\n' ' ')"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured a duplicate beside an assigned wisp"
    has_id f-other || fail "$label: burned a molecule of another formula"
    has_id w-elsewhere || fail "$label: burned another agent's wisp"
    grep -F -q 'Patrol wisp: w-3' "$LAST_OUT" || fail "$label: did not report the surviving wisp"
    drained && fail "$label: a successful reconcile must not drain the session"

    # A surplus burn that fails is retried by a later startup, not fatal.
    seed_state "w-1 $FORMULA open $AGENT true 1" "w-2 $FORMULA open $AGENT true 2"
    run_region "$region" STUB_BURN_FAIL=1
    [ "$RC" -eq 0 ] || fail "$label: a failed surplus burn must not stop the patrol (rc=$RC)"
    grep -F -q 'Patrol wisp: w-2' "$LAST_OUT" || fail "$label: a failed surplus burn must still resume the newest wisp"

    # An in_progress wisp is a patrol wisp too.
    seed_state "w-1 $FORMULA open $AGENT true 1" "w-2 $FORMULA in_progress $AGENT true 2"
    run_region "$region"
    [ "$(ids_where "$FORMULA" "$AGENT")" = "w-2" ] || fail "$label: an in_progress wisp was not counted"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured beside an in_progress wisp"

    # Nothing assigned: this is the gap between ticks, not a reason to pour.
    seed_state
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: an empty hand must leave the session idle (rc=$RC)"
    [ ! -s "$STATE" ] || fail "$label: self-poured a patrol wisp instead of waiting for the order"
    grep -F -q 'IDLE: no assigned patrol wisp' "$LAST_OUT" || fail "$label: an empty hand must print the IDLE signal"
    drained && fail "$label: the idle path must end the turn, not drain"

    # A failed query is not "no wisp": burn nothing and report idle.
    seed_state "w-1 $FORMULA open $AGENT true 1"
    run_region "$region" STUB_LIST_FAIL=1
    has_id w-1 || fail "$label: burned a wisp after a failed wisp query"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured after a failed wisp query"
    grep -F -q 'IDLE: no assigned patrol wisp' "$LAST_OUT" || fail "$label: a failed query must report idle"

    # An empty identity reaches no lookup: an empty --assignee is no filter,
    # so the surplus burn would reach every agent's patrol wisps.
    seed_state "w-mine $FORMULA open $AGENT true 1" "w-theirs $FORMULA open other-city/agent true 2"
    run_region "$region" GC_AGENT=
    has_id w-mine || fail "$label: burned a patrol wisp with an empty GC_AGENT"
    has_id w-theirs || fail "$label: burned another agent's patrol wisp with an empty GC_AGENT"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured with an empty GC_AGENT"
    return 0
}

# ---------------------------------------------------------------------------
# Legs for a startup reconcile region.
# ---------------------------------------------------------------------------

startup_legs() {
    local region="$1" label="$2"

    # Leaked surplus: keep the newest, burn the rest, pour nothing.
    seed_state "w-1 $FORMULA open $AGENT true 1" "w-2 $FORMULA open $AGENT true 2" \
        "w-3 $FORMULA open $AGENT true 3" "f-other mol-other-patrol open $AGENT true 4" \
        "w-elsewhere $FORMULA open someone-else true 5"
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: reconciling leaked wisps must succeed (rc=$RC)"
    [ "$(ids_where "$FORMULA" "$AGENT")" = "w-3" ] ||
        fail "$label: expected only the newest wisp w-3 to survive, found: $(ids_where "$FORMULA" "$AGENT" | tr '\n' ' ')"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured a duplicate beside an assigned wisp"
    has_id f-other || fail "$label: burned a molecule of another formula"
    has_id w-elsewhere || fail "$label: burned another agent's wisp"
    grep -F -q 'Patrol wisp: w-3' "$LAST_OUT" || fail "$label: did not report the surviving wisp"
    drained && fail "$label: a successful reconcile must not drain the session"

    # A surplus burn that fails is retried by a later startup, not fatal.
    seed_state "w-1 $FORMULA open $AGENT true 1" "w-2 $FORMULA open $AGENT true 2"
    run_region "$region" STUB_BURN_FAIL=1
    [ "$RC" -eq 0 ] || fail "$label: a failed surplus burn must not stop the patrol (rc=$RC)"
    grep -F -q 'Patrol wisp: w-2' "$LAST_OUT" || fail "$label: a failed surplus burn must still resume the newest wisp"

    # An in_progress wisp is a patrol wisp too.
    seed_state "w-1 $FORMULA open $AGENT true 1" "w-2 $FORMULA in_progress $AGENT true 2"
    run_region "$region"
    [ "$(ids_where "$FORMULA" "$AGENT")" = "w-2" ] || fail "$label: an in_progress wisp was not counted"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured beside an in_progress wisp"

    # Nothing assigned: pour exactly one and assign it.
    seed_state
    run_region "$region"
    [ "$RC" -eq 0 ] || fail "$label: bootstrapping the first wisp must succeed (rc=$RC)"
    [ "$(ids_where "$FORMULA" "$AGENT" | grep -c .)" -eq 1 ] ||
        fail "$label: expected exactly one assigned patrol wisp after bootstrap"

    # A failed query is not "no wisp".
    seed_state "w-1 $FORMULA open $AGENT true 1"
    run_region "$region" STUB_LIST_FAIL=1
    [ "$RC" -ne 0 ] || fail "$label: a failed wisp query must stop startup"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured after a failed wisp query"
    has_id w-1 || fail "$label: burned a wisp after a failed wisp query"
    drained || fail "$label: a failed wisp query must drain the session so a restarted one reconciles"

    # A bootstrap pour that fails drains.
    seed_state
    run_region "$region" STUB_POUR_FAIL=1
    [ "$RC" -ne 0 ] || fail "$label: a failed bootstrap pour must stop startup"
    drained || fail "$label: a failed bootstrap pour must drain the session"

    # A bootstrap pour that cannot be assigned is reclaimed, then drains.
    seed_state
    run_region "$region" STUB_ASSIGN_FAIL=1
    [ "$RC" -ne 0 ] || fail "$label: a failed bootstrap assignment must stop startup"
    [ ! -s "$STATE" ] || fail "$label: left an unassigned bootstrap wisp behind"
    drained || fail "$label: a failed bootstrap assignment must drain the session"

    # An empty identity reaches no lookup: an empty --assignee is no filter,
    # so the surplus burn would reach every agent's patrol wisps.
    seed_state "w-mine $FORMULA open $AGENT true 1" "w-theirs $FORMULA open other-city/agent true 2"
    run_region "$region" GC_AGENT=
    [ "$RC" -ne 0 ] || fail "$label: an empty GC_AGENT must stop startup"
    has_id w-mine || fail "$label: burned a patrol wisp with an empty GC_AGENT"
    has_id w-theirs || fail "$label: burned another agent's patrol wisp with an empty GC_AGENT"
    [ "$(count_calls 'gc bd mol wisp')" -eq 0 ] || fail "$label: poured with an empty GC_AGENT"
    drained || fail "$label: an empty GC_AGENT must drain the session"
    return 0
}

# ---------------------------------------------------------------------------
# Static: every wisp-tier query in these assets can see the wisps tier and
# asks for both statuses a patrol wisp can have.
# ---------------------------------------------------------------------------

# Scoped to assignee-scoped lookups: that is the shape of every patrol-wisp
# lookup, and it leaves alone prose that merely names a molecule query.
static_legs() {
    local asset bad
    for asset in "$@"; do
        bad=$(grep -n -- '--type=molecule' "$asset" | grep -F 'gc bd list' | grep -F -- '--assignee=' |
            grep -v -- '--include-infra' || true)
        [ -z "$bad" ] || fail "$(basename "$asset"): wisp query without --include-infra (gc bd list hides the wisps tier without it): $bad"
        bad=$(grep -n -- '--status=in_progress --type=molecule' "$asset" || true)
        [ -z "$bad" ] || fail "$(basename "$asset"): single-status wisp lookup; a patrol wisp is open, not in_progress: $bad"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

LEG_NAMES=()
LEG_RESULTS=()

run_leg() {
    local name="$1"
    shift
    LEG_NAMES+=("$name")
    if ( "$@" ); then
        LEG_RESULTS+=("PASS")
        echo "ok   $name"
    else
        LEG_RESULTS+=("FAIL")
        echo "FAIL $name" >&2
    fi
}

# lifted_legs <asset> <formula> <agent> <want-rotate> <want-startup> <profile> <rotate-options>
lifted_legs() {
    local asset="$1" dir counts n
    FORMULA="$2"
    AGENT="$3"
    dir="$REGIONS/$(basename "$asset")"
    counts=$(lift "$asset" "$dir") || fail "could not lift lifecycle blocks from $asset"
    # Behavior first, cardinality last: on a tree that predates a region shape
    # the legs that can run still report what the blocks actually do.
    # C-style loop rather than `seq`: BSD seq prints `1 0` for `seq 1 0`, which
    # would make a file with no rotate regions try to run rotate-1.sh.
    n=0
    while [ "$n" -lt "${counts% *}" ]; do
        n=$((n + 1))
        bash -n "$dir/rotate-$n.sh" || fail "$(basename "$asset") rotate region $n does not parse"
        if [ "$6" = deacon ]; then
            deacon_rotate_legs "$dir/rotate-$n.sh" "$(basename "$asset") rotate region $n"
        else
            rotate_legs "$dir/rotate-$n.sh" "$(basename "$asset") rotate region $n" "$6" "$7"
        fi
    done
    n=0
    while [ "$n" -lt "${counts#* }" ]; do
        n=$((n + 1))
        bash -n "$dir/startup-$n.sh" || fail "$(basename "$asset") startup region $n does not parse"
        if [ "$6" = deacon ]; then
            deacon_startup_legs "$dir/startup-$n.sh" "$(basename "$asset") startup region $n"
        else
            startup_legs "$dir/startup-$n.sh" "$(basename "$asset") startup region $n"
        fi
    done
    [ "$counts" = "$4 $5" ] ||
        fail "$(basename "$asset"): expected $4 rotate and $5 startup region(s), lifted: $counts"
}

write_gc_stub

# Every pour site in each asset is an exit path or a startup, and each count
# below equals that asset's `gc bd mol wisp mol-*-patrol` pour sites, so a new
# pour that skips the resolution cannot hide from these legs. Each asset runs
# twice: against bd's own tier rule, and against gc >= 1.5.0, which appends
# --include-infra to a molecule list. The status half is red under both.
#
# The last arguments are the failure contract. The refinery's rotations drain on
# failure; its prompt's two rules are the formula's blocks restated for the
# agent and stop without draining. The deacon's rotations never pour, never
# drain, and request a restart only on failure; its startup adopts what the
# `deacon-patrol-tick` order assigned and prints IDLE on an empty hand.
for GC_APPENDS_INFRA in 0 1; do
    tier=$([ "$GC_APPENDS_INFRA" = 1 ] && echo "gc appends --include-infra" || echo "bd tier rule")
    run_leg "refinery formula exit paths ($tier)" lifted_legs \
        "$GASTOWN/formulas/mol-refinery-patrol.toml" mol-refinery-patrol testrig/refinery 6 0 strict drain
    run_leg "refinery prompt lifecycle + startup ($tier)" lifted_legs \
        "$GASTOWN/agents/refinery/prompt.template.md" mol-refinery-patrol testrig/refinery 2 1 strict plain
    run_leg "deacon formula next-iteration ($tier)" lifted_legs \
        "$GASTOWN/formulas/mol-deacon-patrol.toml" mol-deacon-patrol deacon 1 0 deacon plain
    run_leg "deacon prompt fallback + startup ($tier)" lifted_legs \
        "$GASTOWN/agents/deacon/prompt.template.md" mol-deacon-patrol deacon 1 1 deacon plain
done
run_leg "wisp queries see the wisps tier and both statuses" static_legs \
    "$GASTOWN/formulas/mol-refinery-patrol.toml" "$GASTOWN/agents/refinery/prompt.template.md" \
    "$GASTOWN/formulas/mol-deacon-patrol.toml" "$GASTOWN/agents/deacon/prompt.template.md"

echo "--- leg summary (tree: $TREE) ---"
failed=0
for i in "${!LEG_NAMES[@]}"; do
    printf '%-4s %s\n' "${LEG_RESULTS[$i]}" "${LEG_NAMES[$i]}"
    [ "${LEG_RESULTS[$i]}" = "PASS" ] || failed=1
done

if [ "$failed" -ne 0 ]; then
    echo "FAIL: patrol wisp lifecycle" >&2
    exit 1
fi
echo "PASS: patrol wisp lifecycle (${#LEG_NAMES[@]} legs)"
