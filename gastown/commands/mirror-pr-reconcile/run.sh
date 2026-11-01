#!/bin/sh
set -eu

usage() {
    echo 'usage: gc gastown mirror-pr-reconcile [record WORK TARGET HEAD_SHA]' >&2
    exit 2
}

bd_update() {
    if [ -n "${GC_RIG:-}" ]; then
        gc bd update --rig="$GC_RIG" "$@"
    else
        gc bd update "$@"
    fi
}

bd_close() {
    if [ -n "${GC_RIG:-}" ]; then
        gc bd close --rig="$GC_RIG" "$@"
    else
        gc bd close "$@"
    fi
}

rig_git() {
    if [ -n "${GC_REPO_ROOT:-${GC_RIG_ROOT:-}}" ]; then
        git -C "${GC_REPO_ROOT:-$GC_RIG_ROOT}" "$@"
    else
        git "$@"
    fi
}

valid_work() {
    case "$1" in
        ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

valid_sha() {
    case "$1" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

valid_identity() {
    valid_work "$1" &&
        git check-ref-format "refs/heads/$2" >/dev/null 2>&1 &&
        git check-ref-format "refs/heads/gc-pr/$2/$1" >/dev/null 2>&1 &&
        valid_sha "$3"
}

escalate() {
    reason=$1
    if ! gc mail send mayor/ -s "ESCALATION: mirror PR for $work" -m "$reason
Work bead: $work"; then
        echo 'mirror-pr-reconcile: mayor notification failed' >&2
    fi
}

record_handoff() {
    [ "$#" -eq 3 ] || usage
    work=$1 target=$2 head=$3
    valid_identity "$work" "$target" "$head" || {
        echo 'mirror-pr-reconcile: invalid work, target, or head' >&2
        return 1
    }
    # The gate, identity and retry marker must be one durable transition.
    bd_update "$work" --status=blocked --assignee="$GC_AGENT" \
        --set-metadata merge_strategy=mirror-pr \
        --set-metadata "pr_branch=gc-pr/$target/$work" \
        --set-metadata "pr_head=$head" \
        --set-metadata "target=$target" \
        --set-metadata merge_result=pull_request_pending \
        --set-metadata mirror_pr_reconcile_pending=true \
        --set-metadata "blocked_reason=Awaiting mirror PR merge" \
        --unset-metadata mirror_pr_last_checked_at \
        --unset-metadata mirror_pr_error \
        --unset-metadata pr_url \
        --unset-metadata merged_sha \
        --unset-metadata gc.routed_to \
        --unset-metadata rejection_reason
}

manual() {
    reason=$1
    bd_update "$work" --status=blocked --assignee='' \
        --set-metadata gc.routed_to=human \
        --set-metadata "blocked_reason=$reason" \
        --unset-metadata mirror_pr_reconcile_pending
    escalate "$reason"
}

reconcile_one() {
    if [ -n "${GC_RIG:-}" ]; then
        pending=$(gc bd list --rig="$GC_RIG" --all --has-metadata-key=mirror_pr_reconcile_pending --limit=0 --json)
    else
        pending=$(gc bd list --all --has-metadata-key=mirror_pr_reconcile_pending --limit=0 --json)
    fi
    row=$(printf '%s\n' "$pending" | jq -ce '
        if type != "array" then error("invalid bead list") else
        [ .[] | select((.metadata.mirror_pr_reconcile_pending // "" | tostring) == "true")
          | select(.status == "blocked" or .status == "closed") ]
        | sort_by(.metadata.mirror_pr_last_checked_at // "", .id) | .[0] // null end')
    [ "$row" != null ] || { echo 'No pending mirror PRs.'; return 0; }
    work=$(printf '%s' "$row" | jq -r '.id // empty')
    status=$(printf '%s' "$row" | jq -r '.status // empty')
    target=$(printf '%s' "$row" | jq -r '.metadata.target // empty')
    branch=$(printf '%s' "$row" | jq -r '.metadata.pr_branch // empty')
    head=$(printf '%s' "$row" | jq -r '.metadata.pr_head // empty')
    result=$(printf '%s' "$row" | jq -r '.metadata.merge_result // empty')
    strategy=$(printf '%s' "$row" | jq -r '.metadata.merge_strategy // empty')
    [ -n "$work" ] || { echo 'mirror-pr-reconcile: missing work id' >&2; return 1; }
    if ! valid_identity "$work" "$target" "$head" ||
       [ "$branch" != "gc-pr/$target/$work" ] || [ "$strategy" != mirror-pr ]; then
        if [ "$status" = blocked ]; then manual 'Invalid mirror PR identity; inspect the handoff.'; fi
        return 1
    fi
    if [ "$status" = closed ]; then
        # The verified close landed before deletion (or deletion before marker clear).
        [ "$result" = mirror_pr_merged ] || return 1
        delete_branch "$branch" "$head"
        bd_update "$work" --unset-metadata mirror_pr_reconcile_pending --unset-metadata mirror_pr_error
        return 0
    fi
    { [ "$result" = pull_request_pending ] || [ "$result" = mirror_pr_merged ]; } || {
        manual 'Invalid mirror PR lifecycle; inspect the handoff.'
        return 1
    }
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    bd_update "$work" --assignee="$GC_AGENT" --set-metadata "mirror_pr_last_checked_at=$now"

    origin=$(rig_git remote get-url origin) || return 1
    case "$origin" in
        /*) state_dir=$origin/gc-pr-state ;;
        *://*|*:*|'') echo 'mirror-pr-reconcile: origin is not a local mirror path' >&2; return 1 ;;
        *) root=$(rig_git rev-parse --show-toplevel) || return 1
           state_dir=$root/$origin/gc-pr-state ;;
    esac
    state_file=$state_dir/$work.json
    if [ ! -e "$state_file" ] && [ ! -L "$state_file" ]; then
        echo "PENDING: $work — mirror has not produced a state file."
        return 0
    fi
    state_json=$(jq -ce --arg work "$work" --arg branch "$branch" --arg target "$target" '
        if type == "object" and .work == $work and .branch == $branch and .target == $target
           and (.state == "open" or .state == "merged" or .state == "closed")
           and (.head_sha | type == "string")
        then . else error("invalid mirror PR state identity") end' "$state_file") || {
        echo "mirror-pr-reconcile: cannot read valid state for $work; will retry" >&2
        return 1
    }
    state=$(printf '%s' "$state_json" | jq -r '.state')
    observed_head=$(printf '%s' "$state_json" | jq -r '.head_sha')
    url=$(printf '%s' "$state_json" | jq -r 'if (.pr_url | type) == "string" then .pr_url else empty end')
    recorded_url=$(printf '%s' "$row" | jq -r '.metadata.pr_url // empty')
    if [ -n "$url" ] && [ -z "$recorded_url" ]; then
        bd_update "$work" --set-metadata "pr_url=$url"
    fi
    case "$state" in
        open) echo "PENDING: $work — mirror PR is open." ;;
        closed)
            manual 'Mirror PR was closed without merging; human review required.'
            return 1 ;;
        merged)
            merge_sha=$(printf '%s' "$state_json" | jq -r 'if (.merge_sha | type) == "string" then .merge_sha else empty end')
            stored_merge=$(printf '%s' "$row" | jq -r '.metadata.merged_sha // empty')
            if [ "$observed_head" != "$head" ] || ! valid_sha "$merge_sha" ||
               { [ "$result" = mirror_pr_merged ] && [ "$stored_merge" != "$merge_sha" ]; }; then
                manual 'Mirror PR merged with an invalid merge SHA or a head different from the validated head.'
                return 1
            fi
            if ! rig_git fetch --no-tags origin "+refs/heads/$target:refs/remotes/origin/$target"; then
                echo 'mirror-pr-reconcile: target fetch failed; will retry' >&2
                return 1
            fi
            if ! GIT_GRAFT_FILE=/dev/null rig_git --no-replace-objects merge-base --is-ancestor "$merge_sha" "refs/remotes/origin/$target"; then
                escalate "Mirror PR merge $merge_sha is not reachable from freshly fetched origin/$target; the bead remains blocked."
                return 1
            fi
            bd_update "$work" --set-metadata merge_result=mirror_pr_merged \
                --set-metadata "merged_sha=$merge_sha" --unset-metadata rejection_reason
            bd_close "$work" --reason "Mirror PR merged to $target at $merge_sha"
            delete_branch "$branch" "$head"
            bd_update "$work" --unset-metadata mirror_pr_reconcile_pending --unset-metadata blocked_reason --unset-metadata mirror_pr_error
            echo "MERGED: closed $work and deleted $branch."
            ;;
    esac
}

delete_branch() {
    delete_ref=refs/heads/$1
    delete_head=$2
    # An absent ref is already cleaned up. Never delete a ref that moved after
    # validation; the lease checks the remote atomically when deleting.
    remote_refs=$(rig_git ls-remote --refs origin "$delete_ref") || return 1
    if [ -n "$remote_refs" ]; then
        remote_head=$(printf '%s\n' "$remote_refs" | jq -Rr 'split("\t")[0]')
        if [ "$remote_head" != "$delete_head" ]; then
            escalate "Closed mirror PR branch $delete_ref moved; refusing deletion."
            return 1
        fi
        rig_git push "--force-with-lease=$delete_ref:$delete_head" origin ":$delete_ref"
    fi
}

[ -n "${GC_AGENT:-}" ] || { echo 'mirror-pr-reconcile: GC_AGENT is empty' >&2; exit 2; }
case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage; reconcile_one ;;
    record) shift; record_handoff "$@" ;;
    *) usage ;;
esac
