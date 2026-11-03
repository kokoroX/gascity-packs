#!/usr/bin/env bash
# Read-only progress check. Unknown means the caller must not kill the target.
if [ -z "${1:-}" ] || [ "$#" -ne 1 ]; then
  echo "shutdown-progress-probe: expected a target" >&2
  exit 2
fi
target=$1
progress="unknown"
now_epoch="$(date -u +%s)"
target_bead=
target_bead_count=
target_rig=
target_session=
target_match_file=

if sessions_json="$(gc session list --state=all --json)" &&
   target_session="$(printf '%s' "$sessions_json" |
     jq -c --arg target "${target%/}" '
       def identities: [.id, .name, .session_name, .alias, .agent_name]
         | map(select((. // "") | length > 0));
       [.sessions[] | select((identities | index($target)) != null)] as $matches
       | if ($matches | length) == 1 then $matches[0] else empty end')"; then
  :
else
  target_session=
fi

if [ -n "$target_session" ]; then
  target_template="$(printf '%s' "$target_session" | jq -r '.template // empty')"
  target_rig="$(printf '%s' "$target_session" | jq -r '.rig // empty')"
  target_session_name="$(printf '%s' "$target_session" | jq -r '.session_name // empty')"
  provider_work_dir="$(printf '%s' "$target_session" | jq -r '.work_dir // empty')"
  if [ -z "$target_rig" ]; then
    case "$target_template" in
      */*) target_rig=${target_template%%/*} ;;
    esac
  fi
  if [ -z "$target_rig" ]; then
    case "$target_session_name" in
      *--*) target_rig=${target_session_name%%--*} ;;
    esac
  fi

  # A dog is city-scoped, so explicitly route the list to the target
  # session's rig store. Select by every exact session identity because a
  # work bead may be assigned by id, name, alias, or configured name.
  if [ -n "$target_rig" ]; then
    target_beads="$(gc bd --rig "$target_rig" list \
      --status=in_progress --json --limit=0)" || target_beads=
  else
    target_beads="$(gc bd list --status=in_progress --json --limit=0)" ||
      target_beads=
  fi
  if [ -n "$target_beads" ]; then
    # Feed both JSON values without argv-sized --argjson data.
    target_match_file="$(mktemp)" || target_match_file=
    if [ -n "$target_match_file" ] &&
       printf '%s\n' "$target_session" "$target_beads" > "$target_match_file"; then
      target_bead_count="$(jq -s '
      .[0] as $session | .[1] as $beads
      | [$session.id, $session.name, $session.session_name,
         $session.alias, $session.agent_name]
        | map(select((. // "") | length > 0)) as $identities
      | [$beads[] | select(.assignee as $a | $identities | index($a))]
      | length' "$target_match_file")" || target_bead_count=
      target_bead="$(jq -rs '
      .[0] as $session | .[1] as $beads
      | [$session.id, $session.name, $session.session_name,
         $session.alias, $session.agent_name]
        | map(select((. // "") | length > 0)) as $identities
      | [$beads[] | select(.assignee as $a | $identities | index($a))]
      | if length == 1 then .[0].id else empty end' \
      "$target_match_file")" || target_bead=
    fi
    [ -z "$target_match_file" ] || rm -f "$target_match_file"
    if [ "$target_bead_count" = 0 ]; then
      progress=none
    fi
  fi
fi

if [ -n "$target_bead" ]; then
  if [ -n "$target_rig" ]; then
    bead_json="$(gc bd --rig "$target_rig" show "$target_bead" --json)" ||
      bead_json=
  else
    bead_json="$(gc bd show "$target_bead" --json)" || bead_json=
  fi
  if [ -z "$bead_json" ]; then
    progress=unknown
  else
    progress=none
    bead_updated="$(printf '%s' "$bead_json" | jq -r '.[0].updated_at // empty')"
    artifact_dir="$(printf '%s' "$bead_json" | jq -r '.[0].metadata.artifact_dir // empty')"
    legacy_work_dir="$(printf '%s' "$bead_json" | jq -r '.[0].metadata.work_dir // empty')"
  fi
fi

if [ -n "$target_bead" ] && [ -n "${bead_json:-}" ]; then
  artifact_source=artifact_dir
  if [ -z "$artifact_dir" ]; then
    artifact_dir=$legacy_work_dir
    artifact_source=work_dir
  fi

  # A progress scan may inspect only a validated per-bead artifact worktree.
  # In particular, never scan legacy work_dir when it is the provider cwd.
  progress_git_common_dir() {
    local repo_dir=$1 common_dir
    common_dir=$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
      return 1
    (CDPATH='' cd -- "$common_dir" 2>/dev/null && pwd -P)
  }
  validate_progress_artifact_dir() {
    local candidate=$1 provider_dir=$2 city_root=$3 rig_name=$4 bead_id=$5
    local candidate_real provider_real candidate_top candidate_common provider_common
    local city_real rig_namespace rig_namespace_real canonical_path
    local provider_parent provider_name
    [ -n "$candidate" ] && [ -d "$candidate" ] || return 1
    # Dogs are city-scoped and normally have no GC_RIG_ROOT. The exact target
    # session's worker directory is the independent repository anchor.
    [ -n "$provider_dir" ] && [ -d "$provider_dir" ] || return 1
    candidate_real=$(CDPATH='' cd -- "$candidate" 2>/dev/null && pwd -P) || return 1
    provider_real=$(CDPATH='' cd -- "$provider_dir" 2>/dev/null && pwd -P) ||
      return 1
    city_real=$(CDPATH='' cd -- "$city_root" 2>/dev/null && pwd -P) || return 1
    case "$rig_name" in
      ""|"."|".."|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    rig_namespace="$city_real/.gc/worktrees/$rig_name"
    rig_namespace_real=$(CDPATH='' cd -- "$rig_namespace" 2>/dev/null && pwd -P) ||
      return 1
    [ "$rig_namespace_real" = "$rig_namespace" ] || return 1
    provider_parent=$(dirname -- "$provider_real")
    provider_name=$(basename -- "$provider_real")
    [ "$provider_parent" = "$rig_namespace_real/polecats" ] || return 1
    case "$provider_name" in
      ""|"."|".."|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    [ "$(basename -- "$candidate_real")" = "$bead_id" ] || return 1
    [ "$(basename -- "$(dirname -- "$candidate_real")")" = worktrees ] || return 1
    canonical_path="$rig_namespace_real/artifacts/worktrees/$bead_id"
    if [ "$candidate_real" != "$canonical_path" ] &&
       [ "$candidate_real" != "$provider_real/worktrees/$bead_id" ]; then
      return 1
    fi
    candidate_top=$(git -C "$candidate_real" rev-parse --show-toplevel 2>/dev/null) ||
      return 1
    candidate_top=$(CDPATH='' cd -- "$candidate_top" 2>/dev/null && pwd -P) || return 1
    [ "$candidate_top" = "$candidate_real" ] || return 1
    candidate_common=$(progress_git_common_dir "$candidate_real") || return 1
    provider_common=$(progress_git_common_dir "$provider_real") || return 1
    [ "$candidate_common" = "$provider_common" ] || return 1
    printf '%s\n' "$candidate_real"
  }
  artifact_candidate=$artifact_dir
  if ! artifact_dir=$(validate_progress_artifact_dir \
      "$artifact_candidate" "$provider_work_dir" "${GC_CITY_PATH:-}" \
      "$target_rig" "$target_bead"); then
    if [ -n "$artifact_candidate" ]; then
      echo "Ignoring unsafe $artifact_source for $target_bead; not scanning provider or unrelated paths." >&2
      progress=unknown
    fi
    artifact_dir=
  fi

  echo "target_bead=$target_bead updated_at=$bead_updated artifact_dir=$artifact_dir" >&2
  # Bead moved within the 7-minute interrogation window (60s+120s+240s = 420s)?
  bead_epoch="$(date -u -d "$bead_updated" +%s 2>/dev/null)" || {
    bead_epoch=0
    progress=unknown
  }
  if [ "$bead_epoch" -gt 0 ] &&
     [ $((now_epoch - bead_epoch)) -lt 420 ]; then
    progress="bead"
  fi
  # Newest worktree file touched within the same window?
  if [ -n "$artifact_dir" ]; then
    if recent_file="$(find "$artifact_dir" -type f \
        -newermt '-7 minutes' -print -quit 2>/dev/null)"; then
      [ -n "$recent_file" ] && progress="worktree:$recent_file"
    else
      progress=unknown
    fi
  fi
fi
echo "progress_signal=$progress"
