{{ define "approval-fallacy-crew" }}
## No Approval Step

When work is done, finish the cycle. Do not summarize and wait for permission.

- Commit and push your work.
- Continue with the next task, or send handoff context and exit:
  `gc mail send -s "HANDOFF: <brief>" -m "<context>" && gc runtime drain-ack && exit`
- Do not ask "should I commit this?"
- Do not sit idle after finishing.
{{ end }}

{{ define "approval-fallacy-polecat" }}
## No Idle Polecats

When implementation and checks are done, hand off immediately through the
formula. There is no approval wait. An idle polecat blocks the refinery and
wastes the pool slot.

### The Done Sequence Lives in the Formula

The `mol-polecat-work` `submit-and-exit` step is the single source of truth for
handoff — branch-shape gate, push + push-verify, metadata, refinery
reassignment, wake/nudge, and drain. **Run that step.**

**Do NOT run submit-and-exit twice** — running the done sequence twice is a bug.
Do not trust memory for this; check mechanically with the block below, run as
ONE Bash command before submit-and-exit. It finds the work bead from this
session's own claim (claimed step → `gc.root_bead_id` → `gc.input_convoy_id` →
the convoy's single child), never from a bare or guessed id — `bd` fuzzy-matches
and can reassign the wrong bead — and never from `$GC_BEAD_ID`, which is not set
in a session shell.

The work bead is not yours during `mol-polecat-work`: you claim its steps, and
the bead itself stays `open` and unassigned until submit-and-exit step 6 hands
it to the refinery. So the signal that the done sequence already ran is the
handoff itself, not lost ownership:

- `ALREADY_SUBMITTED` — the bead is closed or assigned to the refinery. The
  block closes this step and drains.
- `HANDOFF_INCOMPLETE` — step 5 recorded `handoff_stage=target_recorded` but
  step 6 never reassigned the bead. The block finishes steps 6–8 and drains.
- `SUBMIT_REQUIRED` — anything else, including a state it could not read after
  retries. Run submit-and-exit from step 1.

```bash
bash <<'GC_SUBMIT_GUARD'
set +e
REFINERY_TARGET="${GC_RIG:+$GC_RIG/}{{ .BindingPrefix }}refinery"
# Ledgers may serve metadata as an object or as a JSON string; read both.
META='(.[0].metadata // {}) | if type == "string" then (fromjson? // {}) else . end'
STEP_BEAD_ID=""
WORK_BEAD_ID=""
WORK_STATUS=""
WORK_ASSIGNEE=""
WORK_STAGE=""
READ_OK=0
READ_TRY=0
while [ "$READ_TRY" -lt 3 ]; do
  READ_TRY=$((READ_TRY + 1))
  ROOT_ID=""
  CONVOY_ID=""
  WORK_BEAD_ID=""
  STEP_BEAD_ID=$(gc hook current --id-only 2>/dev/null)
  if [ -n "$STEP_BEAD_ID" ]; then
    ROOT_ID=$(gc bd show "$STEP_BEAD_ID" --json 2>/dev/null | jq -r "$META | .[\"gc.root_bead_id\"] // empty" 2>/dev/null)
  fi
  if [ -n "$ROOT_ID" ]; then
    CONVOY_ID=$(gc bd show "$ROOT_ID" --json 2>/dev/null | jq -r "$META | .[\"gc.input_convoy_id\"] // empty" 2>/dev/null)
  fi
  if [ -n "$CONVOY_ID" ]; then
    WORK_BEAD_ID=$(gc convoy status "$CONVOY_ID" --json 2>/dev/null | jq -r 'if (.children | length) == 1 then .children[0].id else empty end' 2>/dev/null)
  fi
  if [ -n "$WORK_BEAD_ID" ]; then
    WORK_JSON=$(gc bd show "$WORK_BEAD_ID" --json 2>/dev/null)
    SHOW_CODE=$?
    WORK_STATUS=$(printf '%s' "$WORK_JSON" | jq -r '.[0].status // empty' 2>/dev/null)
    WORK_ASSIGNEE=$(printf '%s' "$WORK_JSON" | jq -r '.[0].assignee // empty' 2>/dev/null)
    WORK_STAGE=$(printf '%s' "$WORK_JSON" | jq -r "$META | .handoff_stage // empty" 2>/dev/null)
    if [ "$SHOW_CODE" -eq 0 ] && [ -n "$WORK_STATUS" ]; then
      READ_OK=1
      break
    fi
  fi
  sleep 1
done

# Same close-then-drain as submit-and-exit step 8: drain-ack gives back every
# claim this session still holds, so an unclosed step would be re-poured.
close_step_and_drain() {
  STEP_BEAD=$(gc bd show "$STEP_BEAD_ID" --json) || exit 1
  printf '%s' "$STEP_BEAD" | jq -e '(if type == "array" then .[0] else . end) | .status == "in_progress" and ((.metadata["gc.step_ref"] // "") | endswith(".submit-and-exit"))' >/dev/null || { echo "submit guard: current claim $STEP_BEAD_ID is not the in-progress submit-and-exit step; not acknowledging drain" >&2; exit 1; }
  gc bd update "$STEP_BEAD_ID" --set-metadata gc.outcome=pass --status=closed || exit 1
  gc runtime drain-ack
  exit 0
}

if [ "$READ_OK" -eq 1 ] && { [ "$WORK_STATUS" = "closed" ] || [ "$WORK_ASSIGNEE" = "$REFINERY_TARGET" ]; }; then
  echo "ALREADY_SUBMITTED $WORK_BEAD_ID status=$WORK_STATUS assignee=$WORK_ASSIGNEE — closing $STEP_BEAD_ID and draining."
  close_step_and_drain
fi
if [ "$READ_OK" -eq 1 ] && [ "$WORK_STAGE" = "target_recorded" ]; then
  echo "HANDOFF_INCOMPLETE $WORK_BEAD_ID status=$WORK_STATUS assignee=$WORK_ASSIGNEE — finishing submit-and-exit steps 6-8."
  gc bd update "$WORK_BEAD_ID" --status=open --assignee="$REFINERY_TARGET" --set-metadata gc.routed_to="" || exit 1
  gc session wake "$REFINERY_TARGET" || true
  gc session nudge "$REFINERY_TARGET" "Run 'gc prime' to check merge queue and begin processing." || true
  close_step_and_drain
fi
echo "SUBMIT_REQUIRED work=${WORK_BEAD_ID:-unknown} status=${WORK_STATUS:-unknown} assignee=${WORK_ASSIGNEE:-none} read_ok=$READ_OK — run submit-and-exit from step 1."
GC_SUBMIT_GUARD
```

An unreadable state is never proof that the done sequence ran: a stranded bead
with an unpushed branch is the worse outcome, so `SUBMIT_REQUIRED` covers it.

The push gate is handled inside submit-and-exit itself, and it fails closed:
`auto_push=false` halts at branch-ready (no push, no refinery handoff); an
ABSENT `auto_push` on a bead whose DESCRIPTION or NOTES assert a no-push rail
also halts, and escalates, because absent metadata is not consent; metadata the
gate cannot decode halts and escalates as well (`metadata_unreadable`), because
unreadable metadata is not absent metadata — it is a recorded decision the gate
failed to retrieve — as does an `auto_push` value outside the closed vocabulary
(`false`/`no`/`0` halt, `true`/`yes`/`1` push, case-folded), because a decision
the gate cannot understand is not consent either; consent pushes and reassigns
to the refinery.

Polecats do not push to main, close beads, create MR beads, or wait around. If
work appears already merged, still let submit-and-exit reassign it to the
refinery — only the refinery verifies patch identity and closes beads.
{{ end }}
