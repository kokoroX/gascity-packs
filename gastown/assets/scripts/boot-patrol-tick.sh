#!/usr/bin/env bash
#
# boot-patrol-tick.sh — start one boot watchdog cycle.
#
# Plumbing only: keep exactly one patrol wisp assigned to boot and nudge it.
# Judging the deacon stays with boot.

set -euo pipefail

# The boot session's agent name is its wisp assignee ("<binding>.boot").
boot_json=$(gc session list --json | jq -c '[(.sessions // [])[] | select((.template // "") | test("(^|\\.)boot$")) | select(.closed | not)] | first // empty')
if [[ -z "$boot_json" ]]; then
  echo "no boot session"
  exit 0
fi
boot=$(jq -r '.agent_name' <<<"$boot_json")
sid=$(jq -r '.id' <<<"$boot_json")
prefix=${boot%boot}

# Wisp roots are molecules in the wisps tier: --include-infra is required.
held=""
for status in in_progress open; do
  held+=$(gc bd list --assignee="$boot" --status="$status" --type=molecule --include-infra --limit=0 --json | jq -r '.[].id')
done

if [[ -z "$held" ]]; then
  # --json prints one multi-line object on stdout; pipe all of stdout to jq.
  wisp=$(gc bd mol wisp mol-boot-patrol --root-only --var binding_prefix="$prefix" --json | jq -r '.new_epic_id // empty')
  if [[ -z "$wisp" ]]; then
    echo "could not pour boot patrol wisp" >&2
    exit 1
  fi
  if ! gc bd update "$wisp" --assignee="$boot"; then
    # Unassigned, no assignee-scoped query can find it: reclaim by id.
    gc bd mol burn "$wisp" --force || true
    echo "could not assign boot patrol wisp $wisp" >&2
    exit 1
  fi
  echo "poured $wisp for $boot"
else
  echo "$boot already holds: $held"
fi

gc session nudge "$sid" "Patrol tick: run 'gc prime' and work your assigned mol-boot-patrol wisp." >/dev/null
echo "nudged $boot"
