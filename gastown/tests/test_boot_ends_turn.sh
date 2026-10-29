#!/usr/bin/env bash
set -euo pipefail

# Execute the boot prompt fallback and formula finish scripts against a stub gc.
# A successful burn ends the turn; a failed burn or missing wisp requests restart.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export GC_LOG="$tmp/gc.log"

cat >"$tmp/bin/gc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GC_LOG"
case "$*" in
    'bd list '*)
        if [ "$TEST_STATE" = empty ]; then
            printf '[]\n'
        else
            printf '[{"id":"wisp-1"}]\n'
        fi ;;
    'bd mol burn '*) [ "$TEST_STATE" != burn_fail ] || exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gc"

python3 - "$ROOT" "$tmp" <<'PY'
import pathlib
import sys
import tomllib

root, out = map(pathlib.Path, sys.argv[1:])
prompt = (root / 'gastown/agents/boot/prompt.template.md').read_text()
fallback = prompt.split('Use this fallback only if', 1)[1].split('```bash', 1)[1].split('```', 1)[0]
formula = tomllib.loads((root / 'gastown/formulas/mol-boot-patrol.toml').read_text())
finish = next(step['description'] for step in formula['steps'] if step['id'] == 'finish')
script = finish.split('```bash', 1)[1].split('```', 1)[0]
(out / 'fallback.sh').write_text(fallback)
(out / 'finish.sh').write_text(script)
PY

for script in "$tmp/fallback.sh" "$tmp/finish.sh"; do
    bash -n "$script"
    for state in current burn_fail empty; do
        : >"$GC_LOG"
        env -u GC_BEAD_ID PATH="$tmp/bin:$PATH" GC_AGENT=boot TEST_STATE="$state" \
            bash "$script" >"$tmp/output" 2>&1
        if [ "$state" = current ]; then
            grep -q '^bd mol burn wisp-1 --force$' "$GC_LOG" || { printf 'FAIL %s: wisp not burned\n' "$script" >&2; exit 1; }
            ! grep -q '^runtime request-restart$' "$GC_LOG" || { printf 'FAIL %s: unexpected restart\n' "$script" >&2; exit 1; }
            grep -Fq 'Patrol cycle done: burned wisp-1; ending turn until the next tick.' "$tmp/output" || { printf 'FAIL %s: missing completion message\n' "$script" >&2; exit 1; }
        else
            [ "$(tail -n 1 "$GC_LOG")" = 'runtime request-restart' ] || { printf 'FAIL %s: %s must restart\n' "$script" "$state" >&2; exit 1; }
        fi
        ! grep -q '^runtime drain-ack\|^bd mol wisp' "$GC_LOG" || { printf 'FAIL %s: drained or poured\n' "$script" >&2; exit 1; }
    done
done
printf 'PASS: boot finish and fallback end the turn or restart on failure\n'
