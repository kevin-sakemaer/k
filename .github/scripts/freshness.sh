#!/usr/bin/env bash
# Freshness helpers shared by review_gate.sh and github_guard.sh (#8, #15).
# Sourced, not executed. The caller defines fail() and api(), sets REPO and,
# before head_push_time, HEAD_SHA, HEAD_REPO and HEAD_REF.
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
