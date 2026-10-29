#!/usr/bin/env bash
set -euo pipefail

# Execute only the boot startup reconciliation against a stub gc.
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
        case "$TEST_STATE" in
            one) printf '%s\n' '[{"id":"wisp-1","title":"mol-boot-patrol","ephemeral":true,"status":"open","created_at":"2026-01-01T00:00:00Z"}]' ;;
            two) printf '%s\n' '[{"id":"wisp-new","title":"mol-boot-patrol","ephemeral":true,"status":"open","created_at":"2026-02-01T00:00:00Z"},{"id":"wisp-old","title":"mol-boot-patrol","ephemeral":true,"status":"open","created_at":"2026-01-01T00:00:00Z"}]' ;;
            empty) printf '%s\n' '[]' ;;
        esac ;;
    'bd mol burn '*) ;;
    *) printf 'unexpected gc call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gc"

python3 - "$ROOT" "$tmp" <<'PY'
import pathlib
import sys

root, out = map(pathlib.Path, sys.argv[1:])
prompt = (root / 'gastown/agents/boot/prompt.template.md').read_text()
startup = prompt.split('## Startup Protocol', 1)[1].split('```bash', 1)[1].split('```', 1)[0]
step = startup.split('# Step 3:', 1)[1].split('# Step 4:', 1)[0]
(out / 'step3.sh').write_text('# Step 3:' + step)
PY

bash -n "$tmp/step3.sh"
for state in one two empty; do
    : >"$GC_LOG"
    PATH="$tmp/bin:$PATH" GC_AGENT=boot TEST_STATE="$state" bash "$tmp/step3.sh" >"$tmp/output"
    grep -Fxq 'bd list --assignee=boot --status=open,in_progress --type=molecule --include-infra --limit=0 --json' "$GC_LOG" || { printf 'FAIL %s: incorrect list query\n' "$state" >&2; exit 1; }
    ! grep -q '^bd mol wisp\( \|$\)' "$GC_LOG" || { printf 'FAIL %s: poured a wisp\n' "$state" >&2; exit 1; }
    case "$state" in
        one)
            grep -Fxq 'Patrol wisp: wisp-1' "$tmp/output" || { printf 'FAIL one: wisp not adopted\n' >&2; exit 1; }
            ! grep -q '^bd mol burn ' "$GC_LOG" || { printf 'FAIL one: unexpected burn\n' >&2; exit 1; } ;;
        two)
            grep -Fxq 'Patrol wisp: wisp-new' "$tmp/output" || { printf 'FAIL two: newest wisp not adopted\n' >&2; exit 1; }
            [ "$(grep -c '^bd mol burn ' "$GC_LOG")" -eq 1 ] && grep -Fxq 'bd mol burn wisp-old --force' "$GC_LOG" || { printf 'FAIL two: incorrect burn\n' >&2; exit 1; } ;;
        empty)
            grep -Fxq 'IDLE: no assigned patrol wisp, waiting for the next tick.' "$tmp/output" || { printf 'FAIL empty: missing idle signal\n' >&2; exit 1; }
            ! grep -q '^bd mol burn ' "$GC_LOG" || { printf 'FAIL empty: unexpected burn\n' >&2; exit 1; } ;;
    esac
done
printf 'PASS: boot startup reconciles assigned patrol wisps\n'
