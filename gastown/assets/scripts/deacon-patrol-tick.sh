#!/usr/bin/env bash
#
# deacon-patrol-tick.sh — start one deacon patrol cycle.
#
# Plumbing only: assign one patrol wisp to the deacon, or nudge it if it
# already holds one. Judging the town stays with the deacon.

set -euo pipefail

# The deacon session's agent name is its wisp assignee ("<binding>.deacon").
deacon_json=$(gc session list --json | jq -c '[(.sessions // [])[] | select((.template // "") | test("(^|\\.)deacon$")) | select(.closed | not)] | first // empty')
if [[ -z "$deacon_json" ]]; then
  echo "no deacon session"
  exit 0
fi
deacon=$(jq -r '.agent_name' <<<"$deacon_json")
sid=$(jq -r '.id' <<<"$deacon_json")
prefix=${deacon%deacon}

# Wisp roots are molecules in the wisps tier: --include-infra is required.
held=""
for status in in_progress open; do
  held+=$(gc bd list --assignee="$deacon" --status="$status" --type=molecule --include-infra --limit=0 --json | jq -r '.[].id')
done

if [[ -z "$held" ]]; then
  # --json prints one multi-line object on stdout; pipe all of stdout to jq.
  wisp=$(gc bd mol wisp mol-deacon-patrol --root-only --var binding_prefix="$prefix" --json | jq -r '.new_epic_id // empty')
  if [[ -z "$wisp" ]]; then
    echo "could not pour deacon patrol wisp" >&2
    exit 1
  fi
  if ! gc bd update "$wisp" --assignee="$deacon"; then
    # Unassigned, no assignee-scoped query can find it: reclaim by id.
    gc bd mol burn "$wisp" --force || true
    echo "could not assign deacon patrol wisp $wisp" >&2
    exit 1
  fi
  # Assignment triggers a fresh-cycle with a startup nudge; nudging the old
  # session would waste requests before the controller replaces it.
  echo "poured $wisp for $deacon"
  exit 0
else
  echo "$deacon already holds: $held"
fi

gc session nudge "$sid" "Patrol tick: run 'gc prime' and work your assigned mol-deacon-patrol wisp." >/dev/null
echo "nudged $deacon"
