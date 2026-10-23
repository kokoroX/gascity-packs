#!/usr/bin/env bash
# The polecat's submit guard and resume check must read the state that
# mol-polecat-work actually produces.
#
# During mol-polecat-work a polecat claims formula STEPS. The work bead stays
# `open` and unassigned until submit-and-exit step 6 assigns it to the
# refinery, and `$GC_BEAD_ID` is not set in a session shell. The guard used to
# read the convoy through `$GC_BEAD_ID` and treat "work bead not in_progress for
# this session" as already-submitted. The first mistake made every read fail,
# so the guard fell through by accident; once an agent supplied the real convoy
# id, the second made it drain before the handoff, stranding a pushed branch
# that no refinery was ever told about. These tests pin:
#   1. the guard is identical in the polecat prompt and the No Idle Polecats
#      fragment, and neither executable block reads `$GC_BEAD_ID`;
#   2. the guard derives the work bead from the session's claim, and decides
#      already-submitted from the handoff (closed, or assigned to the
#      refinery), finishes a handoff that stopped between steps 5 and 6, and
#      sends everything else, unreadable included, to a full submit-and-exit;
#   3. the resume check verifies the claimed bead, not the work bead.
#
# The blocks are lifted out of the shipped templates and executed against a
# stubbed `gc`, so what is tested is the text an agent reads.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROMPT="$ROOT/gastown/agents/polecat/prompt.template.md"
FRAGMENT="$ROOT/gastown/template-fragments/approval-fallacy.template.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$PROMPT" ]] || fail "polecat prompt not found: $PROMPT"
[[ -f "$FRAGMENT" ]] || fail "approval-fallacy fragment not found: $FRAGMENT"
command -v jq >/dev/null || fail "jq is required"

# extract_block FILE MARKER prints the `bash <<'MARKER'` heredoc through its
# terminator, with the binding prefix rendered the way a pour renders it.
extract_block() {
    awk -v start="bash <<'$2'" -v stop="$2" '
        $0 == start { on = 1 }
        on { print }
        on && $0 == stop { exit }
    ' "$1" | sed 's/{{ \.BindingPrefix }}/admin./g'
}

# --- 1. structure -----------------------------------------------------------

PROMPT_GUARD=$(extract_block "$PROMPT" GC_SUBMIT_GUARD)
FRAGMENT_GUARD=$(extract_block "$FRAGMENT" GC_SUBMIT_GUARD)
RESUME_CHECK=$(extract_block "$PROMPT" GC_RESUME_CHECK)

[[ -n "$PROMPT_GUARD" ]] || fail "polecat prompt has no GC_SUBMIT_GUARD block"
[[ -n "$FRAGMENT_GUARD" ]] || fail "approval-fallacy fragment has no GC_SUBMIT_GUARD block"
[[ -n "$RESUME_CHECK" ]] || fail "polecat prompt has no GC_RESUME_CHECK block"
[[ "$PROMPT_GUARD" == "$FRAGMENT_GUARD" ]] || fail "submit guard differs between the polecat prompt and the fragment"
for block in "$PROMPT_GUARD" "$RESUME_CHECK"; do
    if grep -q 'GC_BEAD_ID' <<<"$block"; then
        fail "an executable block reads \$GC_BEAD_ID, which is not set in a session shell"
    fi
done
[[ $(grep -c "bash <<'GC_SUBMIT_GUARD'" "$PROMPT") -eq 1 ]] || fail "polecat prompt must carry exactly one submit guard"

# --- 2. behavior ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fixture layout under $FIX: hook_current holds the claimed bead id;
# show_<id>.json and convoy_<id>.json answer reads; a missing file is a read
# failure. Every call is appended to $FIX/calls.
cat > "$WORK/bin/gc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/calls"
case "$1 $2" in
    "hook current") [[ -f "$FIX/hook_current" ]] || exit 1; cat "$FIX/hook_current" ;;
    "bd show") [[ -f "$FIX/show_$3.json" ]] || exit 1; cat "$FIX/show_$3.json" ;;
    "convoy status") [[ -f "$FIX/convoy_$3.json" ]] || exit 1; cat "$FIX/convoy_$3.json" ;;
    "bd update"|"runtime drain-ack"|"session wake"|"session nudge") exit 0 ;;
    *) echo "unexpected gc call: $*" >&2; exit 64 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/gc" "$WORK/bin/sleep"

SESSION=jikerental/admin.nux
REFINERY=jikerental/admin.refinery

# new_fixture NAME starts a fixture whose claim is the in-progress
# submit-and-exit step of a molecule poured on convoy cv-1 tracking work-1.
new_fixture() {
    FIX="$WORK/$1"
    mkdir -p "$FIX"
    : > "$FIX/calls"
    echo step-1 > "$FIX/hook_current"
    cat > "$FIX/show_step-1.json" <<JSON
[{"id":"step-1","status":"in_progress","assignee":"$SESSION","metadata":{"gc.root_bead_id":"root-1","gc.step_ref":"mol-polecat-work.submit-and-exit","polecat_session":"$SESSION"}}]
JSON
    echo '[{"id":"root-1","status":"open","metadata":{"gc.input_convoy_id":"cv-1"}}]' > "$FIX/show_root-1.json"
    echo '{"id":"cv-1","children":[{"id":"work-1"}]}' > "$FIX/convoy_cv-1.json"
    work_bead open "" ""
}

# work_bead STATUS ASSIGNEE HANDOFF_STAGE rewrites work-1.
work_bead() {
    local stage=""
    [[ -n "$3" ]] && stage=",\"handoff_stage\":\"$3\""
    echo "[{\"id\":\"work-1\",\"status\":\"$1\",\"assignee\":\"$2\",\"metadata\":{\"branch\":\"polecat/work-1\"$stage}}]" > "$FIX/show_work-1.json"
}

# run_block BLOCK runs it as the agent would, setting OUT and CODE.
run_block() {
    set +e
    OUT=$(cd "$FIX" && env -u BEADS_ACTOR -u GC_SESSION_ID -u GC_AGENT -u GC_BEAD_ID \
        PATH="$WORK/bin:$PATH" FIX="$FIX" GC_RIG=jikerental GC_SESSION_NAME="$SESSION" \
        bash -c "$1" 2>&1)
    CODE=$?
    set -e
}

expect_out() { grep -q -- "$1" <<<"$OUT" || fail "$CASE: expected output '$1', got: $OUT"; }
expect_call() { grep -qx -- "$1" "$FIX/calls" || fail "$CASE: expected call '$1'; calls: $(tr '\n' ';' < "$FIX/calls")"; }
expect_no_call() { ! grep -q -- "$1" "$FIX/calls" || fail "$CASE: unexpected call matching '$1'; calls: $(tr '\n' ';' < "$FIX/calls")"; }

CASE="open unassigned work bead (the stranded-handoff shape)"
new_fixture open
run_block "$PROMPT_GUARD"
expect_out "SUBMIT_REQUIRED work=work-1 status=open assignee=none read_ok=1"
expect_no_call "drain-ack"
expect_no_call "bd update"

CASE="work bead assigned to the refinery"
new_fixture assigned
work_bead open "$REFINERY" target_recorded
run_block "$PROMPT_GUARD"
expect_out "ALREADY_SUBMITTED work-1"
expect_call "bd update step-1 --set-metadata gc.outcome=pass --status=closed"
expect_call "runtime drain-ack"
expect_no_call "bd update work-1"

CASE="work bead closed by the refinery"
new_fixture closed
work_bead closed "$REFINERY" target_recorded
run_block "$PROMPT_GUARD"
expect_out "ALREADY_SUBMITTED work-1 status=closed"
expect_call "runtime drain-ack"

CASE="handoff stopped between steps 5 and 6"
new_fixture incomplete
work_bead open "" target_recorded
run_block "$PROMPT_GUARD"
expect_out "HANDOFF_INCOMPLETE work-1"
expect_call "bd update work-1 --status=open --assignee=$REFINERY --set-metadata gc.routed_to="
expect_call "session wake $REFINERY"
expect_call "bd update step-1 --set-metadata gc.outcome=pass --status=closed"
expect_call "runtime drain-ack"

CASE="root metadata served as a JSON string"
new_fixture string-metadata
echo '[{"id":"root-1","status":"open","metadata":"{\"gc.input_convoy_id\":\"cv-1\"}"}]' > "$FIX/show_root-1.json"
work_bead open "$REFINERY" target_recorded
run_block "$PROMPT_GUARD"
expect_out "ALREADY_SUBMITTED work-1"

CASE="no readable claim"
new_fixture unreadable
rm -f "$FIX/hook_current"
run_block "$PROMPT_GUARD"
expect_out "SUBMIT_REQUIRED work=unknown status=unknown assignee=none read_ok=0"
expect_no_call "drain-ack"

CASE="convoy tracks more than one bead"
new_fixture two-children
echo '{"id":"cv-1","children":[{"id":"work-1"},{"id":"work-2"}]}' > "$FIX/convoy_cv-1.json"
run_block "$PROMPT_GUARD"
expect_out "read_ok=0"
expect_no_call "drain-ack"

CASE="already submitted but the claim is not the submit step"
new_fixture wrong-step
sed -i.bak 's/submit-and-exit/self-review/' "$FIX/show_step-1.json"
work_bead open "$REFINERY" target_recorded
run_block "$PROMPT_GUARD"
[[ "$CODE" -ne 0 ]] || fail "$CASE: guard exited 0"
expect_out "not the in-progress submit-and-exit step"
expect_no_call "drain-ack"

# --- 3. resume check --------------------------------------------------------

CASE="resume: claim still ours"
new_fixture resume-ok
run_block "$RESUME_CHECK"
expect_out "OWNERSHIP_OK step-1"
expect_no_call "drain-ack"

CASE="resume: claim reassigned"
new_fixture resume-lost
sed -i.bak "s#\"assignee\":\"$SESSION\"#\"assignee\":\"jikerental/admin.slit\"#" "$FIX/show_step-1.json"
run_block "$RESUME_CHECK"
expect_out "OWNERSHIP_LOST step-1"
expect_call "runtime drain-ack"

CASE="resume: session tag from another session"
new_fixture resume-tag
sed -i.bak "s#\"polecat_session\":\"$SESSION\"#\"polecat_session\":\"jikerental/admin.slit\"#" "$FIX/show_step-1.json"
run_block "$RESUME_CHECK"
expect_out "OWNERSHIP_LOST step-1"
expect_call "runtime drain-ack"

CASE="resume: no claim for this session"
new_fixture resume-none
rm -f "$FIX/hook_current"
run_block "$RESUME_CHECK"
expect_out "RESUME_INDETERMINATE"
expect_call "runtime drain-ack"

CASE="resume: work bead open and unassigned does not matter"
new_fixture resume-work-open
work_bead open "" ""
run_block "$RESUME_CHECK"
expect_out "OWNERSHIP_OK step-1"

echo "PASS: polecat submit guard and resume check"
