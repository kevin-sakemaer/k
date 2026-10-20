#!/usr/bin/env bash
# Review gate for pull requests. Fails closed on any doubt or API error.
#
# Required environment: REPO (owner/name), PR (number), ACTION (event action).
# GH can point to another gh binary; tests put a fake gh first in PATH.
set -euo pipefail

GH="${GH:-gh}"
: "${REPO:?REPO is required}" "${PR:?PR is required}" "${ACTION:?ACTION is required}"

fail() {
  echo "::error::$*"
  exit 1
}

# Run "gh api" and stop the whole script on any error.
api() {
  local out
  if ! out=$("$GH" api "$@"); then
    echo "::error::GitHub API call failed: gh api $*" >&2
    exit 1
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}

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

remove_approved() {
  local out
  if out=$("$GH" api -X DELETE "repos/$REPO/issues/$PR/labels/review%3Aapproved" 2>&1); then
    return 0
  fi
  case "$out" in
    *"HTTP 404"*) return 0 ;; # Already gone: not an error.
    *"HTTP 403"*) fail "Cannot remove review:approved: read-only token (fork PR?). Ask the Reviewer to remove it." ;;
    *) echo "$out" >&2; fail "Failed to remove review:approved." ;;
  esac
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

main() {
  # Read current state from the API; the event payload may be stale.
  local head labels
  head=$(api "repos/$REPO/pulls/$PR" --jq '[.head.sha, .head.repo.full_name, .head.ref] | @tsv')
  IFS=$'\t' read -r HEAD_SHA HEAD_REPO HEAD_REF <<<"$head"
  [ -n "${HEAD_SHA:-}" ] && [ -n "${HEAD_REPO:-}" ] && [ -n "${HEAD_REF:-}" ] || fail "Could not read the PR head."
  labels=$(api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name')
  echo "Head: $HEAD_SHA ($HEAD_REPO:$HEAD_REF)"
  echo "Labels: $(printf '%s' "$labels" | tr '\n' ' ')"

  has_label() { printf '%s\n' "$labels" | grep -qx "$1"; }

  # A reopened PR is treated like a push: pushes made while the PR was closed
  # produce no synchronize run and no head_ref_force_pushed event.
  if { [ "$ACTION" = "synchronize" ] || [ "$ACTION" = "reopened" ]; } && has_label 'review:approved'; then
    remove_approved
    fail "review:approved removed after a new push; a new review is required"
  fi
  if has_label 'review:changes-requested'; then
    fail "Label review:changes-requested is present."
  fi
  if ! has_label 'review:approved'; then
    fail "Waiting for review: label review:approved is missing"
  fi

  # Freshness: the latest "labeled review:approved" event must be strictly newer
  # than the server-side time the current head was pushed. Commit dates are never
  # used because they can be forged.
  local timeline approved_at head_at source rc event name ts
  timeline=$(api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" \
    --jq '.[] | "\(.event) \(.label.name // "-") \(.created_at // "")"')
  approved_at=$(while read -r event name ts; do
    if [ "$event" = "labeled" ] && [ "$name" = "review:approved" ]; then printf '%s\n' "$ts"; fi
  done <<<"$timeline" | latest)

  rc=0
  head_at=$(activity_push_time) || rc=$?
  if [ "$rc" -eq 0 ]; then
    source="activity API"
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
    head_at=$(printf '%s\n%s\n' "$forced_at" "$run_at" | latest)
    source="fallback: force-push, reopened and head_ref_restored events / first workflow run"
  else
    exit 1
  fi

  echo "review:approved added at: ${approved_at:-none}"
  echo "Head pushed at: ${head_at:-unknown} (source: $source)"
  if ! is_newer "$approved_at" "$head_at"; then
    remove_approved
    fail "review:approved predates the latest push; a new review is required"
  fi
  echo "Review approved."
}

main "$@"
