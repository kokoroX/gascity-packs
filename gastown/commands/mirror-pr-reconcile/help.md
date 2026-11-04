# gastown mirror-pr-reconcile

```text
gc gastown mirror-pr-reconcile
gc gastown mirror-pr-reconcile --all
gc gastown mirror-pr-reconcile record WORK TARGET HEAD_SHA
```

`record` atomically blocks the work bead with its validated head, target,
`gc-pr/<target>/<work>` branch, local mirror origin and a reconciliation marker.
With no arguments, the command checks at most one least-recently-checked marker
for this origin. `--all` checks every matching marker in that order (ties by
bead ID), continues after failures and exits 1 if any check fails. Reconciliation
preserves the existing assignee. The configured origin identifies the mirror;
the host mirror synchronizer publishes state in `refs/gc-pr-state/<work>`.
Older markers without an origin are claimed only when that ref exists.

A missing state ref, open PR or closed PR is checked against the freshly fetched
target: if the handoff head is reachable, the bead is marked merged. Otherwise
missing and open PRs remain pending, and closed PRs are routed to a human.
A merged state must match the handoff identity and its merge commit must be
reachable from the freshly fetched target. Invalid or unreadable state is retried.

A missing PR triggers one mayor notification after 7200 seconds by default;
set `GC_MIRROR_PR_AWAIT_ALERT_SECONDS` to a non-negative integer to change it.
An externally closed bead without merge evidence is escalated and its mirror
branch is retained. After a verified merge, artifact cleanup and branch deletion
are retried through the marker. For blocked cleanup, the marker remains until
branch deletion and the mayor notification succeed; notification can repeat if
clearing the marker fails. Branch deletion uses an exact-head lease.
