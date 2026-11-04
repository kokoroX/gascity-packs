#!/bin/sh
set -eu

usage() {
    echo 'usage: gc gastown mirror-pr-reconcile [--all | record WORK TARGET HEAD_SHA]' >&2
    exit 2
}

bd_update() {
    if [ -n "${GC_RIG:-}" ]; then
        gc bd update --rig="$GC_RIG" "$@" >/dev/null
    else
        gc bd update "$@" >/dev/null
    fi
}

bd_close() {
    if [ -n "${GC_RIG:-}" ]; then
        gc bd close --rig="$GC_RIG" "$@" >/dev/null
    else
        gc bd close "$@" >/dev/null
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
Work bead: $work" >/dev/null; then
        echo 'mirror-pr-reconcile: mayor notification failed' >&2
        return 1
    fi
}

normalize_origin() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *://*|*:*|'') return 1 ;;
        *) root=$(rig_git rev-parse --show-toplevel) || return 1
           printf '%s/%s\n' "$root" "$1" ;;
    esac
}

resolve_origin() {
    remote_origin=$(rig_git config --get remote.origin.url) ||
        remote_origin=$(rig_git remote get-url origin) || return 1
    origin=$(normalize_origin "$remote_origin") || {
        echo 'mirror-pr-reconcile: origin is not a local mirror path' >&2
        return 1
    }
}

record_handoff() {
    [ "$#" -eq 3 ] || usage
    work=$1 target=$2 head=$3
    valid_identity "$work" "$target" "$head" || {
        echo 'mirror-pr-reconcile: invalid work, target, or head' >&2
        return 1
    }
    resolve_origin || return 1
    # The gate, identity and retry marker must be one durable transition.
    bd_update "$work" --status=blocked --assignee="$GC_AGENT" \
        --set-metadata merge_strategy=mirror-pr \
        --set-metadata "pr_branch=gc-pr/$target/$work" \
        --set-metadata "pr_head=$head" \
        --set-metadata "target=$target" \
        --set-metadata merge_result=pull_request_pending \
        --set-metadata mirror_pr_reconcile_pending=true \
        --set-metadata "mirror_pr_origin=$origin" \
        --set-metadata "mirror_pr_recorded_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --unset-metadata mirror_pr_alerted_at \
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
    bd_update "$work" --status=blocked \
        --set-metadata gc.routed_to=human \
        --set-metadata "blocked_reason=$reason" \
        --unset-metadata mirror_pr_reconcile_pending || return 1
    escalate "$reason"
}

target_contains_head() {
    rig_git fetch --no-tags origin "+refs/heads/$target:refs/remotes/origin/$target" || return 2
    if GIT_GRAFT_FILE=/dev/null rig_git --no-replace-objects merge-base --is-ancestor "$head" "refs/remotes/origin/$target"; then
        return 0
    else
        ancestry_status=$?
        [ "$ancestry_status" -eq 1 ] && return 1
        return 2
    fi
}

finish_merged() {
    if ! gc gastown task-artifact-cleanup "$work"; then
        if [ -n "${GC_RIG:-}" ]; then
            cleanup_record=$(gc bd show --rig="$GC_RIG" "$work" --json) || return 1
        else
            cleanup_record=$(gc bd show "$work" --json) || return 1
        fi
        cleanup_state=$(printf '%s' "$cleanup_record" | jq -r 'if type == "array" and length == 1 then .[0].metadata.artifact_cleanup_state // "" else "" end') || return 1
        if [ "$cleanup_state" = blocked ]; then
            # Retain the marker until deletion and notification succeed so failures are retried.
            delete_branch "$branch" "$head" || return 1
            escalate 'Task artifact cleanup is blocked; human review required.' || return 1
            bd_update "$work" --unset-metadata mirror_pr_reconcile_pending || return 1
        fi
        return 1
    fi
    delete_branch "$branch" "$head" || return 1
    bd_update "$work" --unset-metadata mirror_pr_reconcile_pending --unset-metadata blocked_reason --unset-metadata mirror_pr_error || return 1
}

finish_ancestry() {
    bd_update "$work" --set-metadata merge_result=mirror_pr_merged \
        --set-metadata "merged_sha=$head" --set-metadata merged_via=ancestry \
        --unset-metadata rejection_reason || return 1
    if [ "$status" = blocked ]; then
        bd_close "$work" --reason "pr_head $head already reachable from origin/$target" || return 1
    fi
    finish_merged || return 1
    if [ "$status" = blocked ]; then
        echo "MERGED: closed $work and deleted $branch."
    else
        echo "CLEANED: $work — mirror branch removed."
    fi
}

await_alert() {
    threshold=${GC_MIRROR_PR_AWAIT_ALERT_SECONDS-7200}
    case "$threshold" in ''|*[!0-9]*) echo 'mirror-pr-reconcile: invalid alert threshold' >&2; return 1 ;; esac
    recorded=$(printf '%s' "$row" | jq -r '.metadata.mirror_pr_recorded_at // empty')
    alerted=$(printf '%s' "$row" | jq -r '.metadata.mirror_pr_alerted_at // empty')
    if [ -z "$recorded" ]; then
        bd_update "$work" --set-metadata "mirror_pr_recorded_at=$now" || return 1
        recorded=$now
    fi
    elapsed=$(jq -nr --arg recorded "$recorded" '[(now - ($recorded | fromdateiso8601)), 0] | max | floor') || return 1
    if [ -z "$alerted" ] && [ "$(jq -nr --argjson elapsed "$elapsed" --arg threshold "$threshold" '$elapsed >= ($threshold | tonumber)')" = true ]; then
        escalate "PR has not been opened for branch $branch (head $head); waiting $elapsed seconds. Coordinator: review on the host with gc-pr show <mirror-name> $work, then run gc-pr open." || return 1
        bd_update "$work" --set-metadata "mirror_pr_alerted_at=$now" || return 1
    fi
}

reconcile_one() {
    work=$(printf '%s' "$row" | jq -r '.id // empty')
    status=$(printf '%s' "$row" | jq -r '.status // empty')
    target=$(printf '%s' "$row" | jq -r '.metadata.target // empty')
    branch=$(printf '%s' "$row" | jq -r '.metadata.pr_branch // empty')
    head=$(printf '%s' "$row" | jq -r '.metadata.pr_head // empty')
    result=$(printf '%s' "$row" | jq -r '.metadata.merge_result // empty')
    strategy=$(printf '%s' "$row" | jq -r '.metadata.merge_strategy // empty')
    [ -n "$work" ] || { echo 'mirror-pr-reconcile: missing work id' >&2; return 1; }
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    bd_update "$work" --set-metadata "mirror_pr_last_checked_at=$now" || return 1
    if [ "$has_origin" = false ]; then
        bd_update "$work" --set-metadata "mirror_pr_origin=$origin" || return 1
    fi
    if ! valid_identity "$work" "$target" "$head" ||
       [ "$branch" != "gc-pr/$target/$work" ] || [ "$strategy" != mirror-pr ]; then
        if [ "$status" = blocked ]; then manual 'Invalid mirror PR identity; inspect the handoff.'; fi
        return 1
    fi
    if [ "$status" = closed ]; then
        if [ "$result" = mirror_pr_merged ]; then
            finish_merged || return 1
            echo "CLEANED: $work — mirror branch removed."
            return 0
        fi
        if target_contains_head; then
            finish_ancestry
            return $?
        else
            ancestry_status=$?
            [ "$ancestry_status" -eq 1 ] || return 1
        fi
        escalate 'Closed externally without merge evidence; mirror branch left.' || return 1
        bd_update "$work" --unset-metadata mirror_pr_reconcile_pending \
            --set-metadata 'mirror_pr_error=closed externally without merge evidence; mirror branch left' || return 1
        return 0
    fi
    { [ "$result" = pull_request_pending ] || [ "$result" = mirror_pr_merged ]; } || {
        manual 'Invalid mirror PR lifecycle; inspect the handoff.'
        return 1
    }
    state_ref=refs/gc-pr-state/$work
    remote_state=$(rig_git ls-remote --refs origin "$state_ref") || return 1
    if [ -z "$remote_state" ]; then
        if target_contains_head; then
            finish_ancestry
            return $?
        else
            ancestry_status=$?
            [ "$ancestry_status" -eq 1 ] || return 1
        fi
        await_alert || return 1
        echo "PENDING: $work — mirror has not produced a state file."
        return 0
    fi
    rig_git fetch --no-tags origin "+$state_ref:$state_ref" || return 1
    state_tree=''
    if [ "$(rig_git cat-file -t "$state_ref")" = commit ]; then
        state_tree=$(rig_git ls-tree --format='%(objectmode) %(objecttype) %(path)' "$state_ref") || state_tree=''
    fi
    case "$state_tree" in
        '100644 blob state.json'|'100755 blob state.json')
            state_json=$(rig_git cat-file blob "$state_ref:state.json") || state_json='' ;;
        *) state_json='' ;;
    esac
    state_json=$(printf '%s' "$state_json" | jq -ce --arg work "$work" --arg branch "$branch" --arg target "$target" '
        if type == "object" and .work == $work and .branch == $branch and .target == $target
           and (.state == "open" or .state == "merged" or .state == "closed")
           and (.head_sha | type == "string")
        then . else error("invalid mirror PR state identity") end') || {
        echo "mirror-pr-reconcile: cannot read valid state for $work; will retry" >&2
        return 1
    }
    [ -n "$state_json" ] || {
        echo "mirror-pr-reconcile: cannot read valid state for $work; will retry" >&2
        return 1
    }
    state=$(printf '%s' "$state_json" | jq -r '.state')
    observed_head=$(printf '%s' "$state_json" | jq -r '.head_sha')
    url=$(printf '%s' "$state_json" | jq -r 'if (.pr_url | type) == "string" then .pr_url else empty end')
    recorded_url=$(printf '%s' "$row" | jq -r '.metadata.pr_url // empty')
    if [ -n "$url" ] && [ -z "$recorded_url" ]; then
        bd_update "$work" --set-metadata "pr_url=$url" || return 1
    fi
    if [ "$state" = open ] || [ "$state" = closed ]; then
        if target_contains_head; then
            finish_ancestry
            return $?
        else
            ancestry_status=$?
            [ "$ancestry_status" -eq 1 ] || return 1
        fi
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
                --set-metadata "merged_sha=$merge_sha" --unset-metadata rejection_reason || return 1
            bd_close "$work" --reason "Mirror PR merged to $target at $merge_sha" || return 1
            finish_merged || return 1
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
        rig_git push "--force-with-lease=$delete_ref:$delete_head" origin ":$delete_ref" >/dev/null
    fi
}

reconcile() {
    mode=$1
    resolve_origin || return 1
    if [ -n "${GC_RIG:-}" ]; then
        pending=$(gc bd list --rig="$GC_RIG" --all --has-metadata-key=mirror_pr_reconcile_pending --limit=0 --json) || return 1
    else
        pending=$(gc bd list --all --has-metadata-key=mirror_pr_reconcile_pending --limit=0 --json) || return 1
    fi
    rows=$(printf '%s\n' "$pending" | jq -c '
        if type != "array" then error("invalid bead list") else
        [ .[] | select((.metadata.mirror_pr_reconcile_pending // "" | tostring) == "true")
          | select(.status == "blocked" or .status == "closed") ]
        | sort_by(.metadata.mirror_pr_last_checked_at // "", .id) | .[] end') || return 1
    state_refs=$(rig_git ls-remote --refs origin 'refs/gc-pr-state/*') || return 1
    state_refs=$(printf '%s\n' "$state_refs" | jq -Rr 'split("\t") | .[1] // empty') || return 1
    remaining=$rows
    found=false
    failed=0
    while [ -n "$remaining" ]; do
        row=${remaining%%'
'*}
        if [ "$remaining" = "$row" ]; then remaining=''; else remaining=${remaining#*'
'}; fi
        work=$(printf '%s' "$row" | jq -r '.id // empty')
        has_origin=$(printf '%s' "$row" | jq -r '(.metadata // {}) | has("mirror_pr_origin")')
        if [ "$has_origin" = true ]; then
            recorded_origin=$(printf '%s' "$row" | jq -r '.metadata.mirror_pr_origin | if type == "string" then . else "" end')
            normalized=$(normalize_origin "$recorded_origin") || continue
            [ "$normalized" = "$origin" ] || continue
        else
            valid_work "$work" || continue
            printf '%s\n' "$state_refs" | grep -Fx "refs/gc-pr-state/$work" >/dev/null || continue
        fi
        found=true
        if ! (reconcile_one); then
            echo "FAILED: $work — reconciliation failed."
            failed=1
        fi
        [ "$mode" = all ] || break
    done
    [ "$found" = true ] || echo 'No pending mirror PRs.'
    return "$failed"
}

[ -n "${GC_AGENT:-}" ] || { echo 'mirror-pr-reconcile: GC_AGENT is empty' >&2; exit 2; }
case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage; reconcile one ;;
    --all) [ "$#" -eq 1 ] || usage; reconcile all ;;
    record) shift; record_handoff "$@" ;;
    *) usage ;;
esac
