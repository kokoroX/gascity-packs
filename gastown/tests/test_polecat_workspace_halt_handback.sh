#!/usr/bin/env bash
# Run the shipped workspace base-resolution recipe: a halt must release the
# work and close its step before drain-ack can return the session's claims.
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
workspace = [s for s in steps if s["id"] == "workspace-setup"]
check(len(workspace) == 1, "expected exactly one workspace-setup step")
blocks = [b for b in re.findall(r"^```bash\n(.*?)^```$", workspace[0]["description"], re.S | re.M)
          if 'BASE_REMOTE=' in b]
check(len(blocks) == 1, "expected exactly one workspace base-resolution block")
body = blocks[0]
reasons = ("base_branch_diverged", "base_branch_missing")
arms = re.findall(r'^\s*echo "STOP:.*?^\s*exit [01][ \t]*$', body, re.S | re.M)
check(len(arms) == 2, "expected exactly two bounded workspace STOP arms")

# Scope each assertion to its own arm and each update's complete invocation;
# adjacent arms and prose must not be able to supply a missing marker.
for reason in reasons:
    matches = [arm for arm in arms if "halt_reason=" + reason in arm]
    check(len(matches) == 1, reason + ": expected exactly one halt arm")
    arm = matches[0].replace("\\\n", " ")
    lines = arm.splitlines()
    updates = [(i, shlex.split(line)) for i, line in enumerate(lines)
               if line.lstrip().startswith("gc bd update ")]
    work = [(i, args) for i, args in updates if args[3] == "$WORK_BEAD_ID"]
    close = [(i, args) for i, args in updates if args[3] == "$STEP_BEAD_ID"]
    check(len(work) == len(close) == 1, reason + ": expected one work update and one step close")
    work_at, work_args = work[0]
    close_at, close_args = close[0]
    for token in ("--status=open", "--assignee=", "gc.routed_to=", "halt_reason=" + reason,
                  "--append-notes"):
        check(token in work_args, reason + ": work update lacks " + token)
    check(not any(a == "--notes" or a.startswith("--notes=") for _, args in updates for a in args),
          reason + ": halt must never replace notes")
    note = work_args[work_args.index("--append-notes") + 1]
    remedy = "reconcile or push" if reason == "base_branch_diverged" else "fix the rig/bead base configuration"
    check(remedy in note.lower() and "re-sling" in note, reason + ": missing human recovery instructions")
    for token in ("gc.outcome=fail", "gc.failure_class=hard", "gc.failure_reason=" + reason,
                  "--status=closed"):
        check(token in close_args, reason + ": step close lacks " + token)
    drains = [i for i, line in enumerate(lines) if line.strip() == "gc runtime drain-ack"]
    check(len(drains) == 1 and work_at < close_at < drains[0],
          reason + ": require work hand-back, step close, then drain-ack")
    check(arm.rstrip().endswith("exit 1"), reason + ": a halt must still exit non-zero after the hand-back")
print("workspace halt structure: 2 arms passed")

check(shutil.which("jq") is not None, "jq is required to execute the workspace step guard")
rendered = body.replace("{{base_branch}}", "main").replace("{{binding_prefix}}", "gastown.")
valid_step = {"status": "in_progress", "metadata": {"gc.step_ref": "mol-polecat-work.workspace-setup"}}

with tempfile.TemporaryDirectory(prefix="polecat-workspace-halt-") as tmp:
    root = Path(tmp)
    recipe = root / "resolution.sh"
    recipe.write_text(rendered)
    syntax = subprocess.run(["bash", "-n", str(recipe)], capture_output=True, text=True)
    check(syntax.returncode == 0, "lifted recipe is not valid bash: " + syntax.stderr)
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
failure = os.environ["FAILURE"]
if args == ["hook", "current", "--id-only"]:
    if failure == "hook": sys.exit(1)
    print("step-1")
elif args == ["bd", "show", "step-1", "--json"]:
    if failure == "show": sys.exit(1)
    print(os.environ["STEP_JSON"])
elif args[:2] == ["bd", "update"]:
    if failure == "work" and args[2] == "work-1": sys.exit(1)
    if failure == "close" and args[2] == "step-1": sys.exit(1)
elif args[:2] != ["mail", "send"] and args != ["runtime", "drain-ack"]:
    sys.exit("unexpected gc call: " + repr(args))
''')
    git = bin_dir / "git"
    git.write_text('''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "show-ref --verify --quiet refs/remotes/origin/main")
    [[ "$BASE_CASE" == diverged || "$BASE_CASE" == remote ]] ;;
  "show-ref --verify --quiet refs/heads/main")
    [[ "$BASE_CASE" != missing ]] ;;
  "merge-base --is-ancestor refs/heads/main refs/remotes/origin/main")
    [[ "$BASE_CASE" != diverged ]] ;;
  *) printf 'unexpected git call: %s\\n' "$*" >&2; exit 2 ;;
esac
''')
    gc.chmod(0o755)
    git.chmod(0o755)
    cases = 0

    def run(base_case, payload, failure=""):
        global cases
        cases += 1
        log = root / ("calls-%d.jsonl" % cases)
        log.touch()
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   CALL_LOG=str(log), BASE_CASE=base_case, WORK_BEAD_ID="work-1",
                   GC_RIG="testrig", STEP_JSON=json.dumps(payload), FAILURE=failure)
        result = subprocess.run(["bash", str(recipe)], env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    for base_case, reason in zip(("diverged", "missing"), reasons):
        for payload in ([valid_step], valid_step):
            result, calls = run(base_case, payload)
            check(result.returncode == 1, reason + ": halt must exit 1 after the hand-back: " + result.stderr)
            work = [i for i, a in enumerate(calls) if a[:3] == ["bd", "update", "work-1"]]
            close = [i for i, a in enumerate(calls) if a[:3] == ["bd", "update", "step-1"]]
            drains = [i for i, a in enumerate(calls) if a == ["runtime", "drain-ack"]]
            check(len(work) == len(close) == len(drains) == 1, reason + ": missing or repeated hand-back calls")
            check(work[0] < close[0] < drains[0] == len(calls) - 1,
                  reason + ": drain-ack must follow all bead writes")
            for token in ("--status=open", "--assignee=", "gc.routed_to=", "halt_reason=" + reason,
                          "--append-notes"):
                check(token in calls[work[0]], reason + ": work update lacks " + token)
            for token in ("gc.outcome=fail", "gc.failure_class=hard", "gc.failure_reason=" + reason,
                          "--status=closed"):
                check(token in calls[close[0]], reason + ": step close lacks " + token)
            check(["hook", "current", "--id-only"] in calls
                  and ["bd", "show", "step-1", "--json"] in calls,
                  reason + ": current step was not resolved and read")
            mails = [a for a in calls if a[:2] == ["mail", "send"]]
            check(len(mails) == 1, reason + ": witness mail missing")
            mail = mails[0]
            check(mail[2] == "testrig/gastown.witness" and "-s" in mail
                  and reason in mail[mail.index("-s") + 1], reason + ": witness mail missing")
            check("--notify" in mail, reason + ": witness mail lacks --notify")

        # A claim for another step or a step no longer running must not be
        # closed. Failed reads and writes must not acknowledge drain either.
        invalid = ([], {"status": "open", "metadata": valid_step["metadata"]},
                   {"status": "in_progress", "metadata": {"gc.step_ref": "mol-polecat-work.submit-and-exit"}},
                   {"status": "in_progress", "metadata": {}})
        for payload in invalid:
            result, calls = run(base_case, payload)
            check(result.returncode == 1 and "not acknowledging drain" in result.stderr,
                  reason + ": invalid claim must report an error and exit 1")
            check(not any(a[:3] == ["bd", "update", "step-1"] for a in calls),
                  reason + ": invalid claim was closed")
            check(["runtime", "drain-ack"] not in calls, reason + ": invalid claim acknowledged drain")
        for failure in ("work", "hook", "show", "close"):
            result, calls = run(base_case, [valid_step], failure)
            check(result.returncode == 1, reason + ": " + failure + " failure must exit 1")
            check(["runtime", "drain-ack"] not in calls,
                  reason + ": " + failure + " failure acknowledged drain")

    # The two successful resolution paths still record their selected base.
    for base_case, ref in (("remote", "refs/remotes/origin/main"), ("local", "refs/heads/main")):
        result, calls = run(base_case, [valid_step])
        check(result.returncode == 0, base_case + ": normal resolution failed")
        check(calls == [["bd", "update", "work-1", "--set-metadata", "base_ref=" + ref]],
              base_case + ": normal resolution unexpectedly halted")
    print("workspace halt execution: %d cases passed" % cases)

print("polecat workspace halt hand-back tests passed")
PY
