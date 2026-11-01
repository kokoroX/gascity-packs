#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export GC_LOG="$tmp/log"
cat >"$tmp/bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_LOG"
case "$*" in
  'bd list '*) printf '%s\n' "${TEST_BEADS:-[]}" ;;
  'bd mol burn '*) [ "${TEST_BURN_FAIL:-0}" != 1 ] ;;
  'runtime request-restart') ;;
  *) printf 'unexpected call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gc"
python3 - "$ROOT" "$tmp" <<'PY'
import pathlib, sys, tomllib
root, out = map(pathlib.Path, sys.argv[1:])
doc = tomllib.loads((root / 'gastown/formulas/mol-witness-patrol.toml').read_text())
step = next(s for s in doc['steps'] if s['id'] == 'next-iteration')['description']
body = step.split('CURRENT_WISP=${GC_BEAD_ID:-}', 1)[1].split('```', 1)[0]
(out / 'step.sh').write_text('CURRENT_WISP=${GC_BEAD_ID:-}' + body)
prompt = (root / 'gastown/agents/witness/prompt.template.md').read_text()
startup = prompt.split('# Step 2:', 1)[1].split('# Step 3:', 1)[0]
(out / 'startup.sh').write_text('# Step 2:' + startup)
PY
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export PATH="$tmp/bin:$PATH" GC_AGENT=alpha/test.witness
export TEST_BEADS='[{"id":"wrong","title":"other","ephemeral":true,"created_at":"2027"},{"id":"old","title":"mol-witness-patrol","ephemeral":true,"created_at":"2025"},{"id":"new","title":"mol-witness-patrol","ephemeral":true,"created_at":"2026"}]'
: >"$GC_LOG"
bash "$tmp/step.sh" >"$tmp/out"
grep -Fxq 'bd mol burn new --force' "$GC_LOG" || fail 'must burn newest matching wisp'
! grep -q '^runtime request-restart' "$GC_LOG" || fail 'success restarted'
grep -Fq 'ending turn until the next tick' "$tmp/out" || fail 'missing turn completion'
: >"$GC_LOG"
TEST_BURN_FAIL=1 bash "$tmp/step.sh" >"$tmp/out"
grep -Fxq 'runtime request-restart' "$GC_LOG" || fail 'failed burn must restart'
: >"$GC_LOG"
TEST_BEADS='[]' bash "$tmp/step.sh" >"$tmp/out"
grep -Fxq 'runtime request-restart' "$GC_LOG" || fail 'unresolved wisp must restart'
! grep -q '^bd mol wisp\|^runtime drain-ack' "$GC_LOG" || fail 'unexpected pour or drain'
: >"$GC_LOG"
bash "$tmp/startup.sh" >"$tmp/out"
grep -Fxq 'Patrol wisp: new' "$tmp/out" || fail 'startup did not adopt newest'
grep -Fxq 'bd mol burn old --force' "$GC_LOG" || fail 'startup did not burn surplus'
! grep -q 'burn wrong' "$GC_LOG" || fail 'startup burned other molecule'
: >"$GC_LOG"
TEST_BEADS='[]' bash "$tmp/startup.sh" >"$tmp/out"
grep -Fq 'IDLE: no assigned patrol wisp' "$tmp/out" || fail 'empty startup did not idle'
printf '%s\n' 'PASS: witness ends turn and adopts assigned wisps'
