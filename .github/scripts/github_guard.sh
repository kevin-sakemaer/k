#!/usr/bin/env bash
# GitHub guard for pull requests: fails when the PR changes a protected path
# (anything under .github/) unless the label ci:github-change-approved is set.
# Every push (synchronize) or reopen removes that label. Fails closed on any
# doubt or API error.
#
# Required environment: REPO (owner/name), PR (number), ACTION (event action).
# GH can point to another gh binary; tests put a fake gh first in PATH.
#
# The protected paths and the label are hard-coded on purpose: this script runs
# from the base branch, and reading them from k.yaml would let a PR weaken the
# guard it is checked by as soon as the change is merged without the label.
set -euo pipefail

GH="${GH:-gh}"
: "${REPO:?REPO is required}" "${PR:?PR is required}" "${ACTION:?ACTION is required}"

LABEL='ci:github-change-approved'
LABEL_URI='ci%3Agithub-change-approved'
# GitHub lists at most 3000 files per pull request.
MAX_FILES=3000

fail() {
  echo "::error::$*"
  exit 1
}

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

is_protected() {
  case "$1" in
    .github/*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_label() {
  local out
  if out=$("$GH" api -X DELETE "repos/$REPO/issues/$PR/labels/$LABEL_URI" 2>&1); then
    return 0
  fi
  case "$out" in
    *"HTTP 404"*) return 0 ;;
    *"HTTP 403"*) fail "Cannot remove $LABEL: read-only token. Ask the Reviewer to remove it." ;;
    *) echo "$out" >&2; fail "Failed to remove $LABEL." ;;
  esac
}

main() {
  local count labels files protected="" approved=0 f
  count=$(api "repos/$REPO/pulls/$PR" --jq '.changed_files')
  [[ "$count" =~ ^[0-9]+$ ]] || fail "Could not read the number of changed files."
  if [ "$count" -ge "$MAX_FILES" ]; then
    fail "PR changes $count files; GitHub cannot list them all, so protected paths cannot be verified."
  fi
  labels=$(api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name')
  if printf '%s\n' "$labels" | grep -qxF "$LABEL"; then approved=1; fi

  if { [ "$ACTION" = "synchronize" ] || [ "$ACTION" = "reopened" ]; } && [ "$approved" = 1 ]; then
    remove_label
    approved=0
    echo "$LABEL removed after a new push."
  fi

  # Both the new and the previous name of a renamed file are checked.
  files=$(api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" \
    --jq '.[] | .filename, (.previous_filename // empty)')
  while IFS= read -r f; do
    if [ -n "$f" ] && is_protected "$f"; then
      protected+="$f"$'\n'
    fi
  done <<<"$files"

  if [ -z "$protected" ]; then
    echo "No protected path changed."
    return 0
  fi
  echo "Protected paths changed:"
  printf '%s' "$protected" | sed 's/^/  /'
  if [ "$approved" = 1 ]; then
    echo "Approved by label $LABEL."
    return 0
  fi
  fail "This PR changes protected paths; the Reviewer must add the label $LABEL."
}

main "$@"
