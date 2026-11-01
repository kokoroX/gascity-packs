#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys
import tomllib

root = pathlib.Path(sys.argv[1]) / 'gastown'
prompt = (root / 'agents/deacon/prompt.template.md').read_text()
formula_text = (root / 'formulas/mol-deacon-patrol.toml').read_text()
formula = tomllib.loads(formula_text)
order = tomllib.loads((root / 'orders/deacon-patrol-tick.toml').read_text())['order']
steps = {step['id']: step['description'] for step in formula['steps']}

def require(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)

for name, text in [('prompt', prompt), ('formula', formula_text)]:
    require('gc bd formula show' not in text, name + ' uses the body-less formula command')
    require(re.search(r'gc formula show mol-deacon-patrol --json \| jq[^\n]*select\(\.id == "mol-deacon-patrol\.health-scan"\)[^\n]*\.description', text) is not None,
            name + ' must show a one-step formula query')
require('`Read` the formula file' in prompt, 'prompt must forbid reading the formula file')
require('persisted-output file or your own transcript' in prompt, 'prompt must forbid recovering the recipe from saved output')
require('gc agents list' not in formula_text, 'formula uses nonexistent agents list')
for line in formula_text.splitlines():
    if 'gc agent list --json' in line:
        require(re.search(r'gc agent list --json[^\n]*\|\s*jq\b', line) is not None,
                'agent list JSON must go to jq')
    if 'gc session list --json' in line:
        require(re.search(r'gc session list --json[^\n]*\|\s*jq\b', line) is not None,
                'session list JSON must go to jq')
for line in prompt.splitlines():
    if 'gc session list --json' in line:
        require(re.search(r'gc session list --json[^\n]*\|\s*jq\b', line) is not None,
                'prompt session list JSON must go to jq')

system = steps['system-health']
commands = re.findall(r'(?m)^\s*gc doctor[^\n]*', system)
require(len(commands) == 1 and re.match(r'\s*gc doctor --json \| jq\b', commands[0]) is not None,
        'system-health must run doctor once, with JSON piped to jq')
require('.results[]' in commands[0] and 'ascii_downcase != "ok"' in commands[0],
        'doctor must filter non-ok results')
require(not re.search(r'gc doctor(?! --json)[^\n]*\|\s*(?:awk|grep|head)\b', system),
        'system-health must not filter human-readable doctor output')
queue = steps['queue-starvation-check']
require('while read -r AGENT' not in queue, 'queue must not query per agent')
require('group_by(.assignee)' in queue and 'gc bd --rig <rig>' in queue,
        'queue must group open beads per rig')
require(order.get('trigger') == 'cooldown' and bool(order.get('interval')),
        'deacon order must have a cooldown and interval')
print('PASS: deacon context discipline')
PY
