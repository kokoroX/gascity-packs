# gastown merge-strategy

```text
gc gastown merge-strategy WORK [--target BRANCH] [--default STRATEGY]
```

Resolve the work bead's merge strategy, using `--target` when its metadata has no
target and `--default` as the formula default (defaulting to `direct`). The
command prints the final strategy on stdout and its source and any normalization
on stderr. Invalid strategies exit 1; missing arguments or target exit 2. It
only reads the bead and does not send mail or change bead state.
