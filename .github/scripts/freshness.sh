#!/usr/bin/env bash
# Freshness helpers shared by review_gate.sh and github_guard.sh (#8, #15).
# Sourced, not executed. The caller defines fail() and api(), sets REPO and,
# before head_push_time, HEAD_SHA, HEAD_REPO and HEAD_REF (and BASE_REF for
# same_patch).
#
# Rule: a label approves the current head only if its latest "labeled" timeline
# event is strictly newer than the server-side time the head SHA was pushed.
# Commit dates are never used because they can be forged.

# Strict comparison of ISO-8601 UTC timestamps. Empty values or ties are not newer.
is_newer() {
  [ -n "$1" ] && [ -n "$2" ] && [[ "$1" > "$2" ]]
}

latest() {
  # Prints the greatest non-empty line of stdin (ISO-8601 sorts as text).
  local max="" line
  while IFS= read -r line; do
    if [ -n "$line" ] && { [ -z "$max" ] || [[ "$line" > "$max" ]]; }; then
      max="$line"
    fi
  done
  printf '%s' "$max"
}

earliest() {
  local min="" line
  while IFS= read -r line; do
    if [ -n "$line" ] && { [ -z "$min" ] || [[ "$line" < "$min" ]]; }; then
      min="$line"
    fi
  done
  printf '%s' "$min"
}

# True when a "gh api -i" response (headers and body) shows a rate limit.
is_rate_limited() {
  local line lower
  while IFS= read -r line; do
    line="${line%$'\r'}"
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      retry-after:*) return 0 ;;
      x-ratelimit-remaining:*)
        if [ "$(printf '%s' "${lower#*:}" | tr -d ' ')" = 0 ]; then return 0; fi
        ;;
      *"rate limit"*) return 0 ;;
    esac
  done <<<"$1"
  return 1
}

# Server-side time of the push that brought HEAD_SHA, from the activity API.
# Prints the timestamp (possibly empty) and returns 0, or returns 2 when the API
# answers an explicit access 404 or 403 (fallback allowed). Any other error is
# fatal, including a 403 caused by a primary or secondary rate limit: GitHub
# also answers 403 for those, and they must not enable the weaker fallback.
activity_push_time() {
  local probe status
  if probe=$("$GH" api -i "repos/$HEAD_REPO/activity?ref=refs/heads/$HEAD_REF&per_page=1" 2>/dev/null); then
    status=200
  else
    status=$(printf '%s\n' "$probe" | sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')
  fi
  if [ "$status" = 403 ] && is_rate_limited "$probe"; then
    echo "::error::Activity API rate limited (HTTP 403); not falling back. Re-run the job later." >&2
    return 1
  fi
  case "$status" in
    200) ;;
    403 | 404) return 2 ;;
    *)
      # Runs in a command substitution: report on stderr, then return an error.
      echo "::error::Activity API failed (HTTP ${status:-unknown})." >&2
      return 1
      ;;
  esac
  local entries sha ts
  entries=$(api --paginate "repos/$HEAD_REPO/activity?ref=refs/heads/$HEAD_REF&per_page=100" \
    --jq '.[] | "\(.after) \(.timestamp)"')
  while read -r sha ts; do
    if [ "$sha" = "$HEAD_SHA" ]; then
      printf '%s\n' "$ts"
    fi
  done <<<"$entries" | latest
}

# Prints the time of the latest "labeled NAME" event of a timeline listing
# ("event label created_at" lines), or nothing.
label_added_at() {
  local want="$1" event name ts
  while read -r event name ts; do
    if [ "$event" = "labeled" ] && [ "$name" = "$want" ]; then printf '%s\n' "$ts"; fi
  done <<<"$2" | latest
}

# Sets HEAD_AT (possibly empty) and HEAD_AT_SOURCE from the activity API, or
# from the fallback when it answers an access 403 or 404. Takes the timeline
# listing. Exits on any other error. Must not run in a command substitution.
head_push_time() {
  local timeline="$1" rc=0 event name ts
  HEAD_AT=$(activity_push_time) || rc=$?
  if [ "$rc" -eq 0 ]; then
    HEAD_AT_SOURCE="activity API"
  elif [ "$rc" -eq 2 ]; then
    # Fallback: latest of the head_ref_force_pushed, reopened and
    # head_ref_restored timeline events and the first workflow run for the
    # head SHA. Both calls must succeed.
    local forced_at run_at runs
    forced_at=$(while read -r event name ts; do
      case "$event" in
        head_ref_force_pushed | reopened | head_ref_restored) printf '%s\n' "$ts" ;;
      esac
    done <<<"$timeline" | latest)
    runs=$(api --paginate "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&event=pull_request&per_page=100" \
      --jq '.workflow_runs[].created_at')
    run_at=$(printf '%s\n' "$runs" | earliest)
    HEAD_AT=$(printf '%s\n%s\n' "$forced_at" "$run_at" | latest)
    HEAD_AT_SOURCE="fallback: force-push, reopened and head_ref_restored events / first workflow run"
  else
    exit 1
  fi
}

# Same-patch rule (#52). With strict up-to-date checks every merge on main
# makes approved PRs BEHIND, and the update push used to drop the approval
# labels. A label still approves a new head when the PR patch is unchanged:
# the approved SHA is the head when the label was added (latest activity entry
# strictly before its latest "labeled" event; never the PR head), and the
# patch-ids of git diff merge-base..SHA (merge-base with the base branch tip)
# must match for both SHAs. Both git patch-id --stable and --verbatim must
# match: --stable alone ignores whitespace, which can be meaningful (YAML).
# Git objects are fetched into a throwaway bare repository; nothing from the
# PR is checked out or run. Any error or doubt means "not the same patch".
# Needs BASE_REF besides the freshness variables. GATE_GIT_URL is the remote
# to fetch from (tests point it to a local repository).

# Prints the approved SHA for a label added at $1, from the activity API.
approved_sha_at() {
  local entries sha ts best="" best_ts=""
  if ! entries=$("$GH" api --paginate "repos/$HEAD_REPO/activity?ref=refs/heads/$HEAD_REF&per_page=100" \
    --jq '.[] | "\(.after) \(.timestamp)"' 2>/dev/null); then
    echo "Activity API failed: the approved SHA cannot be identified." >&2
    return 1
  fi
  while read -r sha ts; do
    [ -n "$sha" ] && [ -n "$ts" ] || continue
    if [ "$ts" = "$1" ]; then
      echo "A push has the same time as the label: ambiguous approved SHA." >&2
      return 1
    fi
    if [[ "$ts" < "$1" ]] && { [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; }; then
      best="$sha" best_ts="$ts"
    fi
  done <<<"$entries"
  if ! [[ "$best" =~ ^[0-9a-f]{40}$ ]] || [[ "$best" =~ ^0+$ ]]; then
    echo "No push before the label: the approved SHA is unknown." >&2
    return 1
  fi
  printf '%s' "$best"
}

# git on bare repository $1 only, whatever GIT_* variables the caller has
# (a git hook sets GIT_DIR and GIT_INDEX_FILE).
bare_git() {
  local dir="$1"
  shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_NAMESPACE \
    GIT_TERMINAL_PROMPT=0 git --git-dir="$dir" "$@"
}

# Prints "STABLE VERBATIM" patch-ids of merge-base..$2 in bare repository $1.
patch_ids() {
  local mb s v
  mb=$(bare_git "$1" merge-base refs/k/base "$2") || return 1
  bare_git "$1" diff --binary --full-index --no-renames --no-ext-diff \
    --no-textconv --src-prefix=a/ --dst-prefix=b/ "$mb" "$2" >"$1/patch" || return 1
  if ! [ -s "$1/patch" ]; then
    echo "Empty diff for $2: no patch to compare." >&2
    return 1
  fi
  s=$(bare_git "$1" patch-id --stable <"$1/patch" | awk '{print $1}') || return 1
  v=$(bare_git "$1" patch-id --verbatim <"$1/patch" | awk '{print $1}') || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] && [[ "$v" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s %s' "$s" "$v"
}

# same_patch LABEL TIMELINE: returns 0 only when the current head has the same
# patch as the SHA approved by LABEL. Logs the decision and both patch-ids.
# Sets APPROVED_SHA and PATCH_ID. Never exits.
same_patch() {
  local label="$1" at sha dir old="" new="" url
  APPROVED_SHA="" PATCH_ID=""
  at=$(label_added_at "$label" "$2")
  if [ -z "$at" ]; then
    echo "Same-patch check for $label: no labeled event, no approval record: drop."
    return 1
  fi
  if ! [[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || [ -z "${BASE_REF:-}" ]; then
    echo "Same-patch check for $label: head SHA or base branch unknown: drop."
    return 1
  fi
  if ! sha=$(approved_sha_at "$at"); then
    echo "Same-patch check for $label: approved SHA unknown: drop."
    return 1
  fi
  APPROVED_SHA="$sha"
  url="${GATE_GIT_URL:-https://github.com/$REPO.git}"
  if dir=$(mktemp -d) && bare_git "$dir" init -q --bare &&
    bare_git "$dir" fetch -q --no-tags "$url" "+refs/heads/$BASE_REF:refs/k/base" \
      "$sha" "$HEAD_SHA" >&2; then
    old=$(patch_ids "$dir" "$sha") || old=""
    new=$(patch_ids "$dir" "$HEAD_SHA") || new=""
  else
    echo "Could not fetch $BASE_REF, $sha and $HEAD_SHA." >&2
  fi
  [ -n "${dir:-}" ] && rm -rf "$dir"
  echo "Approved SHA for $label: $sha (label added at $at)"
  echo "Patch-id (stable verbatim) at approved SHA: ${old:-error}"
  echo "Patch-id (stable verbatim) at head $HEAD_SHA: ${new:-error}"
  if [ -n "$old" ] && [ "$old" = "$new" ]; then
    PATCH_ID="${new%% *}"
    echo "Same-patch check for $label: same patch: keep."
    return 0
  fi
  echo "Same-patch check for $label: patch differs or unknown: drop."
  return 1
}

# keep_after_push LABEL: on synchronize, returns 0 when LABEL may stay, after
# writing a bot marker comment that records the head as approved-by-rebase.
# Any error returns 1, and the caller removes the label.
keep_after_push() {
  local timeline body
  if ! timeline=$("$GH" api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" \
    --jq '.[] | "\(.event) \(.label.name // "-") \(.created_at // "")"'); then
    echo "Timeline API failed: drop $1." >&2
    return 1
  fi
  same_patch "$1" "$timeline" || return 1
  body="<!-- k-gate:approved-by-rebase label=$1 sha=$HEAD_SHA from=$APPROVED_SHA patch-id=$PATCH_ID -->
\`$1\` kept: $HEAD_SHA has the same patch as the approved $APPROVED_SHA (patch-id $PATCH_ID)."
  if ! "$GH" api -X POST "repos/$REPO/issues/$PR/comments" -f body="$body" >/dev/null; then
    echo "Could not write the approved-by-rebase marker comment: drop $1." >&2
    return 1
  fi
  echo "Marker comment written: $HEAD_SHA approved-by-rebase for $1."
}
