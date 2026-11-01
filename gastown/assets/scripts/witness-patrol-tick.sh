#!/usr/bin/env bash
# Start one patrol cycle for each rig-scoped witness.
set -uo pipefail

if ! agents=$(gc agent list --json | jq -r '
  if (.agents | type) != "array" then error("missing agents array") else
    [.agents[] | select(.suspended != true)
     | .qualified_name // ""
     | select(test("^[^/]+/(witness|[^/]+\\.witness)$"))] | .[]
  end'); then
  echo "failed to list witness agents" >&2
  exit 1
fi

if [[ -z "$agents" ]]; then
  echo "no witness agents"
  exit 0
fi

# Sessions are only used to find a nudge target; sleeping agents may have none.
if ! sessions=$(gc session list --json | jq -ce '
  if (.sessions | type) != "array" then error("missing sessions array") else
    [.sessions[] | select(.closed | not) | select((.agent_name // "") != "" and (.id // "") != "")
     | {key: .agent_name, value: .id}] | from_entries
  end'); then
  echo "failed to list witness sessions" >&2
  exit 1
fi

failures=0
while IFS= read -r agent; do
  rig=${agent%%/*}
  prefix=${agent#*/}
  prefix=${prefix%witness}
  sid=$(jq -r --arg agent "$agent" '.[$agent] // empty' <<<"$sessions")

  if ! held=$(gc bd --rig "$rig" list --assignee="$agent" --status=open,in_progress --type=molecule --include-infra --limit=0 --json |
    jq -er 'if type != "array" then error("expected bead array") else [.[] | select(.title == "mol-witness-patrol" and .ephemeral == true) | .id] | join(" ") end'); then
    echo "failed: could not list patrol wisps for $agent" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ -n "$held" ]]; then
    if [[ -z "$sid" ]]; then
      echo "$agent holds $held, no live session; assignment carries the wake"
    elif gc session nudge "$sid" "Patrol tick: run 'gc prime' and work your assigned mol-witness-patrol wisp." >/dev/null; then
      echo "$agent already holds $held; nudged"
    else
      echo "failed: could not nudge $agent" >&2
      failures=$((failures + 1))
    fi
    continue
  fi

  if ! wisp=$(gc bd --rig "$rig" mol wisp mol-witness-patrol --root-only --var binding_prefix="$prefix" --json | jq -er '.new_epic_id // empty'); then
    echo "failed: could not pour patrol wisp for $agent" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ -z "$wisp" ]]; then
    echo "failed: could not resolve poured patrol wisp for $agent" >&2
    failures=$((failures + 1))
    continue
  fi
  # Keep the wisp open: session_reconciler.go:5584 pins in_progress work,
  # while :6297 excludes open session/infra work from ready non-session work.
  if ! gc bd --rig "$rig" update "$wisp" --assignee="$agent"; then
    gc bd --rig "$rig" mol burn "$wisp" --force || true
    echo "failed: could not assign patrol wisp $wisp to $agent" >&2
    failures=$((failures + 1))
    continue
  fi
  # Assignment produces demand; the controller supplies the startup nudge.
  echo "poured $wisp for $agent"
done <<<"$agents"

[[ "$failures" -eq 0 ]]
