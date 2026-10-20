#!/usr/bin/env bash
# Review gate for pull requests. Fails closed on any doubt or API error.
#
# Required environment: REPO (owner/name), PR (number), ACTION (event action).
# GH can point to another gh binary; tests put a fake gh first in PATH.
set -euo pipefail

GH="${GH:-gh}"
: "${REPO:?REPO is required}" "${PR:?PR is required}" "${ACTION:?ACTION is required}"

# Shared freshness helpers (latest, is_newer, head_push_time, ...), sourced
# from the same base-branch checkout as this script.
# shellcheck source=freshness.sh
. "$(dirname "${BASH_SOURCE[0]}")/freshness.sh"

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

main() {
  # Read current state from the API; the event payload may be stale.
  local head labels
  head=$(api "repos/$REPO/pulls/$PR" --jq '[.head.sha, .head.repo.full_name, .head.ref, (.draft | tostring)] | @tsv')
  IFS=$'\t' read -r HEAD_SHA HEAD_REPO HEAD_REF DRAFT <<<"$head"
  [ -n "${HEAD_SHA:-}" ] && [ -n "${HEAD_REPO:-}" ] && [ -n "${HEAD_REF:-}" ] || fail "Could not read the PR head."
  case "${DRAFT:-}" in
    true | false) ;;
    *) fail "Could not read the PR draft state." ;;
  esac
  labels=$(api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name')
  echo "Head: $HEAD_SHA ($HEAD_REPO:$HEAD_REF)"
  echo "Draft: $DRAFT"
  echo "Labels: $(printf '%s' "$labels" | tr '\n' ' ')"

  has_label() { printf '%s\n' "$labels" | grep -qx "$1"; }

  # A reopened PR is treated like a push: pushes made while the PR was closed
  # produce no synchronize run and no head_ref_force_pushed event.
  if { [ "$ACTION" = "synchronize" ] || [ "$ACTION" = "reopened" ]; } && has_label 'review:approved'; then
    remove_approved
    fail "review:approved removed after a new push; a new review is required"
  fi
  # Draft-first rule (#27): a draft PR never passes, even with review:approved.
  # The approval label is kept: marking the PR ready re-runs this gate.
  if [ "$DRAFT" = true ]; then
    fail "PR is a draft: mark it ready (gh pr ready) once CI is fully green; the review gate never passes on a draft PR"
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
  local timeline approved_at head_at source
  timeline=$(api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" \
    --jq '.[] | "\(.event) \(.label.name // "-") \(.created_at // "")"')
  approved_at=$(label_added_at 'review:approved' "$timeline")

  head_push_time "$timeline"
  head_at="$HEAD_AT"
  source="$HEAD_AT_SOURCE"

  echo "review:approved added at: ${approved_at:-none}"
  echo "Head pushed at: ${head_at:-unknown} (source: $source)"
  if ! is_newer "$approved_at" "$head_at"; then
    remove_approved
    fail "review:approved predates the latest push; a new review is required"
  fi
  echo "Review approved."
}

main "$@"
