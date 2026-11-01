# gastown mirror-pr-reconcile

```text
gc gastown mirror-pr-reconcile
gc gastown mirror-pr-reconcile record WORK TARGET HEAD_SHA
```

`record` atomically blocks the work bead with its validated head, target,
`gc-pr/<target>/<work>` branch and a reconciliation marker. With no arguments,
the command checks at most one least-recently-checked marker in the rig.
The origin must be a local mirror repository: its `gc-pr-state/<work>.json`
is written by the host mirror synchronizer.

A missing file or open PR leaves the bead blocked. A merged PR closes it only
when the file's work, branch, target and head match the handoff and the merge
commit is reachable from the freshly fetched origin target. A closed-unmerged
PR is routed to a human. Invalid or unreadable files never close the bead.
After closure, branch deletion is retried through the durable marker and uses
an exact-head lease to avoid deleting a branch that moved. The original task
artifact is preserved.
