#!/usr/bin/env bash
# witness-liveness-map.sh — build the witness orphan-recovery liveness snapshot.
# Read-only: query sessions and session beads, then emit one JSON object. A
# failure means liveness was not verified and must never be treated as absence.
# JSON travels through files so large session rosters do not exceed ARG_MAX.
# Exit 0 for a usable map, 1 for a query, jq, or empty-map schema failure. Every
# exit-1 path prints one parseable JSON line; exit 2 (run.sh without pack
# context) prints nothing on stdout.

set -u

tmp=$(mktemp -d) || {
  echo "witness-liveness-map: cannot create temporary directory" >&2
  printf '{"map":{},"map_count":0,"session_count":0}\n'
  exit 1
}
trap 'rm -rf "$tmp"' EXIT
sessions="$tmp/sessions.json"
beads="$tmp/session-beads.json"
query_rc=0

gc session list --state=all --json >"$sessions" || { echo "witness-liveness-map: session list failed" >&2; query_rc=1; }
gc bd list --type=session --label=gc:session --include-infra --include-gates --all --json --limit=0 >"$beads" || { echo "witness-liveness-map: session bead list failed" >&2; query_rc=1; }

session_count=0
if [ "$query_rc" -eq 0 ]; then
  session_count=$(jq -r '(.sessions // []) | length' "$sessions" 2>/dev/null) || session_count=
  case "$session_count" in
    ''|*[!0-9]*)
      echo "witness-liveness-map: jq could not count sessions" >&2
      session_count=0
      query_rc=1
      ;;
  esac
fi
if [ "$query_rc" -ne 0 ]; then
  # A failed query leaves the roster/counts unknown. Report zeros, as the old
  # inline build did, so callers do not mistake it for an empty but readable map.
  printf '{"map":{},"map_count":0,"session_count":0}\n'
  exit 1
fi

result=$(jq -cn --slurpfile sessions "$sessions" --slurpfile session_beads "$beads" '
  def add($m; $key; $state; $closed):
    if (($key // "") | length) == 0 then $m
    else $m + {($key): (if $closed then "closed" else ($state // "") end)}
    end;
  (reduce ($sessions[0].sessions // [])[] as $s ({};
      add(.; $s.id;         $s.state; ($s.closed // false))
    | add(.; $s.name;       $s.state; ($s.closed // false))
    | add(.; $s.session_name; $s.state; ($s.closed // false))
    | add(.; $s.alias;      $s.state; ($s.closed // false))
    | add(.; $s.agent_name; $s.state; ($s.closed // false))
  )) as $from_sessions
  | (reduce ($session_beads[0] // [])[] as $b ($from_sessions;
      add(.; $b.metadata.configured_named_identity; $b.metadata.state; ($b.status == "closed")))) as $map
  | {map: $map, map_count: ($map | length), session_count: (($sessions[0].sessions // []) | length)}') || {
  echo "witness-liveness-map: jq could not build the map" >&2
  printf '{"map":{},"map_count":0,"session_count":%s}\n' "$session_count"
  exit 1
}
printf '%s\n' "$result"
map_count=$(printf '%s\n' "$result" | jq -r '.map_count') || { echo "witness-liveness-map: jq could not read map count" >&2; exit 1; }
if [ "$map_count" -eq 0 ] && [ "$session_count" -gt 0 ]; then
  echo "witness-liveness-map: empty map with sessions present" >&2
  exit 1
fi
