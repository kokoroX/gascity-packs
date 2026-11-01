#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$ROOT/gastown/formulas/mol-refinery-patrol.toml" "$ROOT/gastown/agents/refinery/prompt.template.md" <<'PY'
import re
import sys
from pathlib import Path

for name, count in zip(sys.argv[1:], (7, 4)):
    text = Path(name).read_text()
    assert len(re.findall(r'mol wisp mol-refinery-patrol', text)) == count, name
    assert not re.search(r'--assignee=["\']?\$GC_AGENT["\']?\s+--status=in_progress', text), name
    lookups = [line for line in text.splitlines() if 'gc bd list' in line and '--type=molecule' in line and '--assignee=' in line]
    assert lookups, name
    for line in lookups:
        assert '--status=open,in_progress' in line and '--include-infra' in line, (name, line)
        if 'CURRENT_WISP=' in line:
            assert 'select(.title == "mol-refinery-patrol" and .ephemeral == true)' in line, (name, line)
            assert 'sort_by(.created_at, .id) | last' in line, (name, line)
    if 'prompt.template.md' in name:
        assert 'select(.title == "mol-refinery-patrol" and .ephemeral == true)' in text
        assert 'sort_by(.created_at, .id) | reverse | .[].id' in text
print('PASS: refinery wisps remain open and resumable')
PY
