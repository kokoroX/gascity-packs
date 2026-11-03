# gc gastown shutdown-progress-probe <target>

Read-only progress check for a shutdown-dance target. The command inspects
the target session's exact identities, its single claimed work bead, and the
validated per-bead worktree. On stdout its last line is
`progress_signal=<value>`:

- `none`: the target has no claimed work, or nothing in it has moved.
- `unknown`: the lookup was inconclusive (missing or ambiguous session,
  failed query, unreadable bead timestamp, unsafe artifact path). Treat this
  as "do not kill and escalate"; it is never evidence of idleness.
- `bead`: the claimed bead's `updated_at` is inside the 7-minute
  interrogation window.
- `worktree:<path>`: a file under the validated worktree was touched inside
  the same window.

Diagnostics go to stderr. Exit 0 means the probe completed, including
`unknown`; exit 2 means the target argument or pack context is missing.
