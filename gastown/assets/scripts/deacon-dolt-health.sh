#!/usr/bin/env bash
# deacon-dolt-health.sh — run and classify `gc dolt health --json`.
# Prints one classification line, `DOLT_HEALTH: ...`, exactly as the patrol
# step used to print it; the evaluate branch then prints the report. The error
# branches add DOLT_HEALTH_RC and DOLT_HEALTH_STDERR for the caller's mail.
# Exit 0 for every classification; run.sh exits 2 without pack context.

set -u

err=$(mktemp) || {
  echo "deacon-dolt-health: cannot create temporary file" >&2
  exit 1
}
trap 'rm -f "$err"' EXIT

json=$(gc dolt health --json 2>"$err")
rc=$?
stderr=$(head -c 2000 "$err" 2>/dev/null | tr '\n' ' ')

# Exit 78 is the Dolt pack failing to resolve a gc-managed server's port: with
# no runtime state file there is no gc-managed Dolt in this city, and with a
# state file but no running server the gc-managed Dolt is down. gc --json
# reports a missing command as error.code json_command_not_found; without the
# JSON envelope it says `unknown command "dolt"` on stderr.
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 78 ] && printf '%s' "$stderr" | grep -q 'cannot resolve runtime port' &&
     printf '%s' "$stderr" | grep -q 'dolt-state.json (missing)'; then
    echo "DOLT_HEALTH: not-applicable (no gc-managed Dolt runtime in this city; bd owns the server or none exists)"
  elif [ "$rc" -eq 78 ] && printf '%s' "$stderr" | grep -q 'present but not running'; then
    echo "DOLT_HEALTH: outage (the gc-managed Dolt server is not running) -> CRITICAL row"
  elif printf '%s' "$json" | jq -e '.error.code == "json_command_not_found"' >/dev/null 2>&1 ||
     printf '%s\n%s\n' "$stderr" "$json" | grep -q -e 'unknown command "dolt"' -e 'unknown command "health"'; then
    echo "DOLT_HEALTH: not-applicable (gc dolt health does not exist in this city; no Dolt pack)"
  else
    echo "DOLT_HEALTH: error (gc dolt health --json exited $rc)"
    echo "DOLT_HEALTH_CAUSE: gc dolt health --json exited $rc"
    echo "DOLT_HEALTH_STDERR: $stderr"
    echo "DOLT_HEALTH_RC: $rc"
  fi
elif ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "DOLT_HEALTH: error (gc dolt health --json printed no JSON report)"
  echo "DOLT_HEALTH_CAUSE: gc dolt health --json exited 0 without a JSON report"
  echo "DOLT_HEALTH_STDERR: $stderr"
  echo "DOLT_HEALTH_RC: $rc"
else
  printf '%s' "$json" | jq -r '
    if (.skipped | type) == "object" then "DOLT_HEALTH: not-applicable (" + (.skipped.reason // "skipped") + ")"
    elif .applicable == false then "DOLT_HEALTH: not-applicable (" + (.reason // "no Dolt data plane") + ")"
    else "DOLT_HEALTH: evaluate" end'
  printf '%s\n' "$json"
fi
