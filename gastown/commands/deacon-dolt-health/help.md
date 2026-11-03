# gc gastown deacon-dolt-health

Run `gc dolt health --json` once and classify the result for the deacon patrol.
stdout starts with exactly one `DOLT_HEALTH:` line:

- `DOLT_HEALTH: not-applicable (...)`: no gc-managed Dolt to report on — the
  Dolt pack is absent, the scope is bd-owned and skipped, or no runtime state
  exists.
- `DOLT_HEALTH: outage (...)`: the gc-managed Dolt server is down; this routes
  to the CRITICAL row.
- `DOLT_HEALTH: error (...)`: the check itself could not run, or exited 0
  without a JSON report. Extra lines carry what the caller needs:
  `DOLT_HEALTH_CAUSE:` (the wording for the escalation body),
  `DOLT_HEALTH_STDERR:` (first 2000 bytes, newlines flattened to spaces) and
  `DOLT_HEALTH_RC:` (the exit code). The command does not send mail itself.
- `DOLT_HEALTH: evaluate`: a usable report follows on stdout as JSON.

Exit 0 for every classification; exit 2 only when `GC_PACK_DIR` is missing.
