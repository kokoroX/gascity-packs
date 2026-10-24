#!/usr/bin/env bash
# The mol-polecat-work branch-shape gate must hand the work bead back.
#
# The gate fails closed when the session is not on `polecat/<bead-id>`, which
# is correct. What used to be wrong is what it left behind: it closed the step
# bead, drain-acked and exited, so the workflow failed with nobody paged and a
# work bead still assigned with no recovery instructions (jkr-6t0y sat for 49
# minutes). The content gate below it already does the right thing: return the
# work bead to the pool open/unassigned with a halt_reason and recovery notes,
# nudge mayor and the rig witness, THEN close the step and drain-ack.
#
# These tests pin both halves:
#   1. structure — what the gate SAYS it does (hand-back, two escalations,
#      append-only notes, step close, drain-ack last);
#   2. execution — the shipped bash block lifted out of the step and run
#      against stubbed `gc`/`git`, so ordering and the nudge-failure path are
#      observed rather than merely word-matched.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-polecat-work.toml"

python3 - "$FORMULA" <<'PY'
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


with open(sys.argv[1], "rb") as handle:
    steps = tomllib.load(handle)["steps"]
step = [s for s in steps if s["id"] == "submit-and-exit"]
check(len(step) == 1, "expected exactly one submit-and-exit step")
blocks = [b for b in re.findall(r"^```bash\n(.*?)^```$", step[0]["description"], re.S | re.M)
          if "BRANCH SHAPE GATE FAILED" in b]
check(len(blocks) == 1, "expected exactly one branch-shape gate block")
body = blocks[0]

# The gate's OWN region: its failure message through the exit that ends it.
# Anchor the terminator to a line of its own, otherwise the jq guard's inline
# `exit 1;` would truncate the region before the hand-back is even reached.
start_match = re.compile(r'^[ \t]*echo "BRANCH SHAPE GATE FAILED"', re.M).search(body)
check(start_match is not None, "branch-shape gate has no failure message")
start = start_match.start()
end = re.compile(r"^[ \t]*exit 1[ \t]*$", re.M).search(body, start)
check(end is not None, "branch-shape gate has no terminating `exit 1` line")
region = body[start:end.end()]
folded = region.replace("\\\n", " ")
check(folded.rstrip().endswith("exit 1"), "the gate region must end with `exit 1`")

# --- structure: what the gate says ------------------------------------------
check(folded.count('gc bd update "$WORK_BEAD_ID"') == 1,
      "expected exactly one work-bead hand-back")
work_match = re.search(r'gc bd update "\$WORK_BEAD_ID".*?(?=\n[ \t]*for ESCALATE_TARGET in )',
                       folded, re.S)
check(work_match is not None, "work-bead hand-back is not followed by the escalation loop")
work_args = shlex.split(work_match.group(0))
for token in ("--status=open", "--assignee=", "gc.routed_to=",
              "halt_reason=branch_shape_gate", "--append-notes"):
    check(token in work_args, "work-bead hand-back lacks " + token)

try:
    tokens = shlex.split(folded)
except ValueError as error:
    raise SystemExit("FAIL: gate region is not parseable as shell: %s" % error)
check(not any(t == "--notes" or t.startswith("--notes=") for t in tokens),
      "the hand-back must only append notes, never replace them")

note = work_args[work_args.index("--append-notes") + 1]
for token in ("$CURRENT_BRANCH", "$EXPECTED_BRANCH", "$BASE_REF",
              "re-running the workspace-setup step"):
    check(token in note, "recovery note lacks " + token)

# One `gc session nudge` in a loop over exactly the two escalation targets:
# the gate issues two nudges at run time, one to mayor and one to the rig's
# witness, without duplicating the message template.
check(folded.count("gc session nudge") == 1,
      "expected exactly one nudge statement")
loop = 'for ESCALATE_TARGET in mayor "${GC_RIG:+$GC_RIG/}{{binding_prefix}}witness"; do'
check(loop in folded, "nudges must target mayor and the rig witness")
nudge_line = [line for line in folded.splitlines() if "gc session nudge" in line]
check(len(nudge_line) == 1, "expected exactly one nudge command line")
for token in ("BRANCH SHAPE GATE", "$WORK_BEAD_ID", "$CURRENT_BRANCH", "$EXPECTED_BRANCH"):
    check(token in nudge_line[0], "nudge message lacks " + token)

step_lines = [line for line in folded.splitlines()
              if line.lstrip().startswith('gc bd update "$STEP_BEAD_ID"')]
check(len(step_lines) == 1, "expected exactly one step-bead close")
step_args = shlex.split(step_lines[0])
for token in ("gc.outcome=fail", "gc.failure_class=hard",
              "gc.failure_reason=branch_shape_gate", "--status=closed"):
    check(token in step_args, "step close lacks " + token)

check(folded.count("gc runtime drain-ack") == 1,
      "expected exactly one drain-ack")
positions = {
    "work hand-back": folded.index('gc bd update "$WORK_BEAD_ID"'),
    "first nudge": folded.index("gc session nudge"),
    "step close": folded.index('gc bd update "$STEP_BEAD_ID"'),
    "drain-ack": folded.index("gc runtime drain-ack"),
}
ordered = list(positions.items())
for (earlier, earlier_at), (later, later_at) in zip(ordered, ordered[1:]):
    check(earlier_at < later_at, "%s must precede %s" % (earlier, later))
print("branch-shape gate structure: passed")

# --- execution: run the lifted block ----------------------------------------
check(shutil.which("jq") is not None, "jq is required to execute the gate")
rendered = body.replace("{{convoy_id}}", "cv-1").replace("{{binding_prefix}}", "gastown.")
valid_step = [{"id": "step-1", "status": "in_progress",
               "metadata": {"gc.step_ref": "mol-polecat-work.submit-and-exit"}}]

with tempfile.TemporaryDirectory(prefix="polecat-branch-gate-") as tmp:
    root = Path(tmp)
    recipe = root / "gate.sh"
    recipe.write_text(rendered)
    syntax = subprocess.run(["bash", "-n", str(recipe)], capture_output=True, text=True)
    check(syntax.returncode == 0, "lifted gate is not valid bash: " + syntax.stderr)

    bin_dir = root / "bin"
    bin_dir.mkdir()
    gc = bin_dir / "gc"
    gc.write_text(r'''#!/usr/bin/env python3
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as handle:
    handle.write(json.dumps(args) + "\n")
if args == ["convoy", "status", "cv-1", "--json"]:
    print('{"id":"cv-1","children":[{"id":"work-1"}]}')
elif args == ["bd", "show", "work-1", "--json"]:
    print('[{"id":"work-1","status":"open","assignee":"","metadata":{"base_ref":"refs/remotes/origin/main","branch":"polecat/work-1"}}]')
elif args == ["hook", "current", "--id-only"]:
    print("step-1")
elif args == ["bd", "show", "step-1", "--json"]:
    print(os.environ["STEP_JSON"])
elif args[:2] == ["bd", "update"]:
    sys.exit(0)
elif args[:2] == ["session", "nudge"]:
    sys.exit(1 if os.environ.get("FAILURE") == "nudge" else 0)
elif args == ["runtime", "drain-ack"]:
    sys.exit(0)
else:
    sys.exit("unexpected gc call: " + repr(args))
''')
    git = bin_dir / "git"
    git.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "branch --show-current") printf '%s\n' "$CURRENT_BRANCH_STUB" ;;
  *) printf 'unexpected git call: %s\n' "$*" >&2; exit 2 ;;
esac
''')
    gc.chmod(0o755)
    git.chmod(0o755)

    def run(label, current_branch, step_payload, failure=""):
        log = root / (label + ".jsonl")
        log.write_text("")
        env = dict(os.environ,
                   PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   CALL_LOG=str(log), CURRENT_BRANCH_STUB=current_branch,
                   GC_RIG="testrig", STEP_JSON=json.dumps(step_payload),
                   FAILURE=failure)
        result = subprocess.run(["bash", str(recipe)], env=env,
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    def indices(calls, prefix):
        return [i for i, a in enumerate(calls) if a[:len(prefix)] == prefix]

    # (a) wrong branch: hand back, escalate twice, then close and drain-ack.
    result, calls = run("shape-fail", "polecat/other", valid_step)
    check(result.returncode == 1,
          "wrong branch must exit 1 after handing back: " + result.stderr)
    work = indices(calls, ["bd", "update", "work-1"])
    nudges = indices(calls, ["session", "nudge"])
    close = indices(calls, ["bd", "update", "step-1"])
    drains = indices(calls, ["runtime", "drain-ack"])
    check(len(work) == 1, "expected exactly one work-bead hand-back")
    check(len(nudges) == 2, "expected exactly two nudges, got %d" % len(nudges))
    check(len(close) == 1, "expected exactly one step-bead close")
    check(len(drains) == 1, "expected exactly one drain-ack")
    for token in ("--status=open", "--assignee=", "gc.routed_to=",
                  "halt_reason=branch_shape_gate", "--append-notes"):
        check(token in calls[work[0]], "work-bead hand-back lacks " + token)
    check(calls[nudges[0]][2] == "mayor", "first nudge must go to mayor")
    check(calls[nudges[1]][2] == "testrig/gastown.witness",
          "second nudge must go to the rig witness")
    for index in nudges:
        for token in ("BRANCH SHAPE GATE", "work-1", "polecat/other", "polecat/work-1"):
            check(token in calls[index][3], "nudge message lacks " + token)
    for token in ("gc.outcome=fail", "gc.failure_class=hard",
                  "gc.failure_reason=branch_shape_gate", "--status=closed"):
        check(token in calls[close[0]], "step close lacks " + token)
    check(calls[-1] == ["runtime", "drain-ack"],
          "drain-ack must be the last call, got " + repr(calls[-1]))
    check(work[0] < nudges[0] < close[0] < drains[0],
          "order must be hand-back, nudges, step close, drain-ack")

    # (b) a failed nudge warns but must not swallow the step close or drain.
    result, calls = run("nudge-fail", "polecat/other", valid_step, failure="nudge")
    check(result.returncode == 1, "wrong branch must still exit 1 when nudge fails")
    check("WARNING: could not nudge" in result.stdout + result.stderr,
          "a failed nudge must warn by hand")
    check(len(indices(calls, ["bd", "update", "step-1"])) == 1,
          "a failed nudge swallowed the step close")
    check(indices(calls, ["runtime", "drain-ack"]), "a failed nudge swallowed drain-ack")

    # (c) correct branch: the gate is silent and takes no action at all.
    result, calls = run("shape-pass", "polecat/work-1", valid_step)
    check(result.returncode == 0, "correct branch must pass the gate: " + result.stderr)
    check(not indices(calls, ["bd", "update", "work-1"]),
          "correct branch must not hand the work bead back")
    check(not indices(calls, ["session", "nudge"]),
          "correct branch must not nudge anyone")
    check(not indices(calls, ["runtime", "drain-ack"]),
          "correct branch must not acknowledge drain")

    # (d) the step claim is not this in-progress step: no close and no
    # drain-ack, but the work bead has already been handed back before that
    # check, and both escalations fire.
    invalid_step = [{"id": "step-1", "status": "open",
                     "metadata": {"gc.step_ref": "mol-polecat-work.submit-and-exit"}}]
    result, calls = run("claim-wrong", "polecat/other", invalid_step)
    check(result.returncode == 1, "invalid step claim must exit 1")
    check("not acknowledging drain" in result.stderr,
          "invalid step claim must say it is not acknowledging drain")
    check(not indices(calls, ["bd", "update", "step-1"]),
          "invalid step claim was closed")
    check(not indices(calls, ["runtime", "drain-ack"]),
          "invalid step claim acknowledged drain")
    check(len(indices(calls, ["bd", "update", "work-1"])) == 1,
          "work bead must be handed back before the claim check")
    check(len(indices(calls, ["session", "nudge"])) == 2,
          "both escalations must fire before the claim check")

    print("branch-shape gate execution: 4 cases passed")

print("polecat branch-shape gate hand-back tests passed")
PY
