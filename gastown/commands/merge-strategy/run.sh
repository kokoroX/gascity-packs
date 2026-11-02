#!/bin/sh
set -eu

usage() {
    echo 'usage: gc gastown merge-strategy WORK [--target BRANCH] [--default STRATEGY]' >&2
    exit 2
}

[ "$#" -gt 0 ] || usage
work=$1
case "$work" in ''|-*) usage ;; esac
shift
target_fallback=''
default_strategy=direct
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; target_fallback=$2; shift 2 ;;
        --default) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; default_strategy=$2; shift 2 ;;
        *) usage ;;
    esac
done

if [ -n "${GC_RIG:-}" ]; then
    bead=$(gc bd show --rig="$GC_RIG" "$work" --json)
else
    bead=$(gc bd show "$work" --json)
fi
case "$bead" in
    *\[*) bead="[${bead#*\[}" ;;
    *) echo 'merge-strategy: bead response contains no JSON array' >&2; exit 1 ;;
esac
metadata=$(printf '%s\n' "$bead" | jq -ce '.[0].metadata // {}')
target=$(printf '%s\n' "$metadata" | jq -r '.target // empty')
target=${target:-$target_fallback}
[ -n "$target" ] || { echo 'merge-strategy: target is empty' >&2; exit 2; }
strategy=$(printf '%s\n' "$metadata" | jq -r '.merge_strategy // empty')
existing_pr=$(printf '%s\n' "$metadata" | jq -r '.existing_pr // empty')
if [ -n "$strategy" ]; then
    source=metadata.merge_strategy
else
    direct_targets=${GC_MERGE_STRATEGY_DIRECT_TARGETS:-}
    set -f
    for pattern in $direct_targets; do
        # Each entry is intentionally a glob.
        # shellcheck disable=SC2254
        case "$target" in
            $pattern) strategy=direct; source="target $target matched GC_MERGE_STRATEGY_DIRECT_TARGETS"; break ;;
        esac
    done
    set +f
    if [ -z "$strategy" ]; then
        if [ -n "${GC_MERGE_STRATEGY_DEFAULT:-}" ]; then
            strategy=$GC_MERGE_STRATEGY_DEFAULT
            source=GC_MERGE_STRATEGY_DEFAULT
        else
            strategy=$default_strategy
            source=default_merge_strategy
        fi
    fi
fi
case "$strategy" in
    direct|mr|pr|mirror-pr) ;;
    *) echo "Invalid merge strategy '$strategy' (from $source). Expected direct, mr, pr, or mirror-pr." >&2; exit 1 ;;
esac
if [ "$strategy" = pr ]; then
    strategy=mr
    echo 'merge_strategy=pr normalized to mr.' >&2
fi
if [ -n "$existing_pr" ] && [ "$strategy" = direct ]; then
    strategy=mr
    echo 'metadata.existing_pr requires pull-request handoff; using merge_strategy=mr.' >&2
fi
echo "merge strategy: $strategy (from $source)" >&2
printf '%s\n' "$strategy"
