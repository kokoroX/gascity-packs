#!/usr/bin/env bash
# The witness patrol must persistently escalate work beads that a gate halt
# parked open/unassigned/unrouted, without re-routing them itself.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-witness-patrol.toml"

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
from datetime import datetime, timedelta, timezone


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


with open(sys.argv[1], "rb") as handle:
    formula = tomllib.load(handle)
steps = formula["steps"]
check(formula["vars"].get("halt_escalation_interval", {}).get("default") == "3600",
      "halt_escalation_interval must default to 3600")

ids = [s["id"] for s in steps]
check(ids.count("escalate-halted-beads") == 1,
      "expected exactly one escalate-halted-beads step")
check(ids.index("recover-orphaned-beads") < ids.index("escalate-halted-beads")
      < ids.index("check-refinery"),
      "escalate-halted-beads must sit between recover-orphaned-beads and check-refinery")

step = steps[ids.index("escalate-halted-beads")]
check(step.get("needs") == ["recover-orphaned-beads"],
      "escalate-halted-beads must need recover-orphaned-beads")
refinery = [s for s in steps if s["id"] == "check-refinery"]
check(len(refinery) == 1 and refinery[0].get("needs") == ["escalate-halted-beads"],
      "check-refinery must need escalate-halted-beads")
description = step["description"]

blocks = re.findall(r"^```bash\n(.*?)^```$", description, re.S | re.M)
check(len(blocks) == 1, "expected exactly one bash block in escalate-halted-beads")
body = blocks[0]

# --- structure: the step may only read and escalate -------------------------
# `gc sling` appears only inside the mail body's advice to the mayor, never as
# an invocation, so the check is anchored to command position.
check(re.search(r"(?m)^\s*gc\s+sling\b", body) is None,
      "the sweep must never re-sling by itself")
for token in ("--status=", "--assignee=", "gc.routed_to="):
    check(token not in body, "the sweep must not write " + token)

updates = [line for line in body.splitlines() if line.lstrip().startswith("gc bd update")]
check(len(updates) == 1, "expected exactly one gc bd update")
update_args = shlex.split(updates[0].split("||", 1)[0])
check(len(update_args) == 6 and update_args[3] == "$BEAD_ID"
      and update_args[4] == "--set-metadata"
      and update_args[5].startswith("halt_escalated_at=")
      and update_args[5] != "halt_escalated_at=",
      "the only write must be --set-metadata halt_escalated_at=<stamp>")

check("gc bd list" in body, "candidates must come from gc bd list")
check("--has-metadata-key=halt_reason" in body,
      "the listing must select on halt_reason")
check(re.search(r"(?m)^\s*bd\s", body) is None,
      "the sweep must go through gc bd, not bare bd")
check("gc mail send mayor/" in body, "the escalation must be mailed to mayor")
check("gc session nudge" not in body,
      "the escalation must be persistent mail, not a one-shot nudge")
check("next-iteration" in description.rstrip()[-400:],
      "the step must hand off to next-iteration in its exit criteria")
print("halted-bead sweep structure: passed")

# --- execution: run the lifted block against a stubbed gc -------------------
check(shutil.which("jq") is not None, "jq is required to execute the sweep")
rendered = body.replace("{{halt_escalation_interval}}", "3600").replace(
    "{{binding_prefix}}", "gastown.")


def bead(bead_id, status="open", assignee="", halt_reason=None, routed="",
         escalated=None, branch=None, base_ref="refs/remotes/origin/main"):
    metadata = {"gc.routed_to": routed, "branch": branch or ("polecat/" + bead_id),
                "base_ref": base_ref}
    if halt_reason is not None:
        metadata["halt_reason"] = halt_reason
    if escalated is not None:
        metadata["halt_escalated_at"] = escalated
    return {"id": bead_id, "status": status, "assignee": assignee, "metadata": metadata}


def stamp(delta):
    return (datetime.now(timezone.utc) + delta).strftime("%Y-%m-%dT%H:%M:%SZ")


halted = bead("work-1", halt_reason="branch_shape_gate")

with tempfile.TemporaryDirectory(prefix="witness-halted-sweep-") as tmp:
    root = Path(tmp)
    recipe = root / "sweep.sh"
    recipe.write_text(rendered)
    syntax = subprocess.run(["bash", "-n", str(recipe)], capture_output=True, text=True)
    check(syntax.returncode == 0, "lifted sweep is not valid bash: " + syntax.stderr)

    bin_dir = root / "bin"
    bin_dir.mkdir()
    gc = bin_dir / "gc"
    gc.write_text('''#!/usr/bin/env python3
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as handle:
    handle.write(json.dumps(args) + "\\n")
failure = os.environ.get("FAILURE", "")
if args[:2] == ["bd", "list"] and "--has-metadata-key=halt_reason" in args:
    if failure == "list":
        sys.exit(1)
    if failure == "garbage":
        print("not json")
    else:
        print(os.environ["LIST_JSON"])
elif args[:2] == ["mail", "send"]:
    sys.exit(1 if failure == "mail" else 0)
elif args[:2] == ["bd", "update"]:
    sys.exit(0)
else:
    sys.exit("unexpected gc call: " + repr(args))
''')
    gc.chmod(0o755)

    def run(label, payload, failure=""):
        log = root / (label + ".jsonl")
        log.write_text("")
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   CALL_LOG=str(log), GC_RIG="testrig",
                   LIST_JSON=json.dumps(payload), FAILURE=failure)
        result = subprocess.run(["bash", str(recipe)], env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    def mail_indices(calls):
        return [i for i, a in enumerate(calls) if a[:3] == ["mail", "send", "mayor/"]]

    def update_indices(calls):
        return [i for i, a in enumerate(calls) if a[:2] == ["bd", "update"]]

    # 1. A halted, unrouted bead is mailed and stamped, mail first.
    result, calls = run("hit", [halted])
    check(result.returncode == 0, "hit: sweep failed: " + result.stderr)
    mails = mail_indices(calls)
    updates = update_indices(calls)
    check(len(mails) == 1, "hit: expected exactly one mail")
    check(len(updates) == 1, "hit: expected exactly one update")
    mail_args = calls[mails[0]]
    check("work-1" in mail_args[4] and "branch_shape_gate" in mail_args[4],
          "hit: mail subject lacks the bead or halt reason")
    check("polecat/work-1" in mail_args[6] and "refs/remotes/origin/main" in mail_args[6],
          "hit: mail body lacks the branch or base ref")
    update_args = calls[updates[0]]
    check(update_args[2] == "work-1" and update_args[3] == "--set-metadata"
          and update_args[4].startswith("halt_escalated_at=")
          and update_args[4] != "halt_escalated_at=",
          "hit: unexpected update: " + repr(update_args))
    check(mails[0] < updates[0], "hit: the stamp must be written after the mail succeeds")

    # 2. A bead escalated this cycle is not escalated again.
    result, calls = run("fresh", [bead("work-1", halt_reason="branch_shape_gate",
                                       escalated=stamp(timedelta(0)))])
    check(result.returncode == 0, "fresh: sweep failed: " + result.stderr)
    check(not mail_indices(calls) and not update_indices(calls),
          "fresh: a recently escalated bead was escalated again")

    # 3. An expired stamp escalates again.
    result, calls = run("stale", [bead("work-1", halt_reason="branch_shape_gate",
                                       escalated=stamp(timedelta(hours=-2)))])
    check(result.returncode == 0, "stale: sweep failed: " + result.stderr)
    check(len(mail_indices(calls)) == 1 and len(update_indices(calls)) == 1,
          "stale: an expired escalation was not repeated")

    # 4. Only parked, unrouted beads are candidates.
    unrelated = [
        bead("assigned", halt_reason="branch_shape_gate", assignee="testrig/gastown.polecat"),
        bead("routed", halt_reason="branch_shape_gate", routed="testrig/gastown.refinery"),
        bead("no-reason"),
        bead("empty-reason", halt_reason=""),
        bead("blank-reason", halt_reason="   \t "),
        bead("closed", status="closed", halt_reason="branch_shape_gate"),
    ]
    result, calls = run("unrelated", unrelated)
    check(result.returncode == 0, "unrelated: sweep failed: " + result.stderr)
    check(not mail_indices(calls) and not update_indices(calls),
          "unrelated: a bead that is not parked and unrouted was escalated")

    # 5. A failed mail must not stamp, so the next cycle retries it.
    result, calls = run("mail-fail", [halted], failure="mail")
    check(len(mail_indices(calls)) == 1, "mail-fail: no mail was attempted")
    check("WARNING: could not mail mayor" in result.stdout + result.stderr,
          "mail-fail: the failure was not reported")
    check(not update_indices(calls),
          "mail-fail: stamped a bead whose mail never went out")

    # 6. A failed listing is reported, not read as "nothing parked".
    result, calls = run("list-fail", [halted], failure="list")
    mails = mail_indices(calls)
    check(len(mails) == 1 and "halted-bead sweep disabled" in calls[mails[0]][4],
          "list-fail: the disabled sweep was not reported")
    check(not update_indices(calls), "list-fail: an update ran without candidates")

    # 7. A non-JSON payload is a filter failure, same fail-safe path.
    result, calls = run("garbage", [halted], failure="garbage")
    mails = mail_indices(calls)
    check(len(mails) == 1 and "halted-bead sweep disabled" in calls[mails[0]][4],
          "garbage: the disabled sweep was not reported")
    check(not update_indices(calls), "garbage: an update ran without candidates")
    print("halted-bead sweep execution: 7 cases passed")

print("witness halted-bead sweep tests passed")
PY
