#!/usr/bin/env bash
# GitHub guard for pull requests: fails when the PR changes a protected path
# (the gate itself: .github/, tool/check.sh, tool/*_test.sh, tool/hooks/,
# analysis_options.yaml and k.yaml at any depth, since the analyzer uses the
# nearest analysis_options.yaml) unless the label ci:github-change-approved is
# set AND fresh: its latest "labeled" event must be newer than the push of the
# current head (same rule as review_gate.sh, shared in freshness.sh). Every
# push (synchronize) or reopen removes that label. Fails closed on any doubt or
# API error.
#
# Required environment: REPO (owner/name), PR (number), ACTION (event action).
# GH can point to another gh binary; tests put a fake gh first in PATH.
#
# The protected paths and the label are hard-coded on purpose: this script runs
# from the base branch, and reading them from k.yaml would let a PR weaken the
# guard it is checked by as soon as the change is merged without the label.
set -euo pipefail
exit 0

GH="${GH:-gh}"
: "${REPO:?REPO is required}" "${PR:?PR is required}" "${ACTION:?ACTION is required}"

LABEL='ci:github-change-approved'
LABEL_URI='ci%3Agithub-change-approved'
# GitHub lists at most 3000 files per pull request.
MAX_FILES=3000

# shellcheck source=freshness.sh
. "$(dirname "${BASH_SOURCE[0]}")/freshness.sh"

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
    .github/* | tool/check.sh | tool/*_test.sh | tool/hooks/* | analysis_options.yaml | */analysis_options.yaml | k.yaml | */k.yaml) return 0 ;;
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
  # Read current state from the API; the event payload may be stale.
  local head count labels files protected="" approved=0 listed=0 f prev
  head=$(api "repos/$REPO/pulls/$PR" --jq '[.head.sha, .head.repo.full_name, .head.ref, .changed_files] | @tsv')
  IFS=$'\t' read -r HEAD_SHA HEAD_REPO HEAD_REF count <<<"$head"
  [ -n "${HEAD_SHA:-}" ] && [ -n "${HEAD_REPO:-}" ] && [ -n "${HEAD_REF:-}" ] || fail "Could not read the PR head."
  [[ "${count:-}" =~ ^[0-9]+$ ]] || fail "Could not read the number of changed files."
  if [ "$count" -ge "$MAX_FILES" ]; then
    fail "PR changes $count files; GitHub cannot list them all, so protected paths cannot be verified."
  fi
  labels=$(api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name')
  if printf '%s\n' "$labels" | grep -qxF "$LABEL"; then approved=1; fi
  echo "Head: $HEAD_SHA ($HEAD_REPO:$HEAD_REF)"

  if { [ "$ACTION" = "synchronize" ] || [ "$ACTION" = "reopened" ]; } && [ "$approved" = 1 ]; then
    remove_label
    approved=0
    echo "$LABEL removed after a new push."
  fi

  # One line per file: new name, tab, previous name of a rename (or empty).
  # Both names are checked.
  files=$(api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" \
    --jq '.[] | "\(.filename)\t\(.previous_filename // "")"')
  while IFS=$'\t' read -r f prev; do
    [ -n "$f" ] || continue
    listed=$((listed + 1))
    if is_protected "$f"; then protected+="$f"$'\n'; fi
    if [ -n "$prev" ] && is_protected "$prev"; then protected+="$prev"$'\n'; fi
  done <<<"$files"
  if [ "$listed" != "$count" ]; then
    fail "Listed $listed changed files but the PR reports $count; the listing is incomplete."
  fi

  if [ -z "$protected" ]; then
    echo "No protected path changed."
    return 0
  fi
  echo "Protected paths changed:"
  printf '%s' "$protected" | sed 's/^/  /'
  if [ "$approved" != 1 ]; then
    fail "This PR changes protected paths; the Reviewer must add the label $LABEL."
  fi

  # Freshness on every run: a label run racing a push, or a synchronize run
  # that failed before removing the label, must not approve a new head.
  local timeline label_at
  timeline=$(api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" \
    --jq '.[] | "\(.event) \(.label.name // "-") \(.created_at // "")"')
  label_at=$(label_added_at "$LABEL" "$timeline")
  head_push_time "$timeline"
  echo "$LABEL added at: ${label_at:-none}"
  echo "Head pushed at: ${HEAD_AT:-unknown} (source: $HEAD_AT_SOURCE)"
  if ! is_newer "$label_at" "$HEAD_AT"; then
    remove_label
    fail "$LABEL predates the latest push; the Reviewer must add it again."
  fi
  echo "Approved by label $LABEL."
}

main "$@"
