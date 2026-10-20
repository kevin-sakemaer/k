#!/usr/bin/env bash
# Auto-merge policy for one PR (#18, #33). Fails closed on API errors.
# Base main: enable squash auto-merge on opened, reopened, ready_for_review
# or labeled review:approved, never on a draft and never on edited.
# Any other base, on any event (retarget included): disable auto-merge if
# it is enabled, because the main ruleset does not protect that base.
# The workflow has no job-level filter: all filtering is done here.
#
# Required environment: PR (number), ACTION (event action).
# Optional: BASE (base ref), DRAFT (true/false), LABEL (label name).
# GH can point to another gh binary; tests put a fake gh first in PATH.
set -euo pipefail

GH="${GH:-gh}"
: "${PR:?PR is required}" "${ACTION:?ACTION is required}"

# auto_state: prints true or false (auto-merge armed); exits 1 on any error.
auto_state() {
  local state
  if ! state=$("$GH" pr view "$PR" --json autoMergeRequest --jq '.autoMergeRequest != null'); then
    echo "::error::Cannot read the auto-merge state of PR #$PR." >&2
    exit 1
  fi
  case "$state" in
    true | false) printf '%s\n' "$state" ;;
    *)
      echo "::error::Unexpected auto-merge state '$state' for PR #$PR." >&2
      exit 1
      ;;
  esac
}

disable_auto() {
  local state out
  state=$(auto_state)
  if [ "$state" = false ]; then
    echo "Auto-merge is not enabled on PR #$PR: nothing to disable."
    return 0
  fi
  if out=$("$GH" pr merge "$PR" --disable-auto 2>&1); then
    echo "Auto-merge disabled on PR #$PR."
    return 0
  fi
  echo "$out" >&2
  # Whatever the error says, succeed only if auto-merge is now really off.
  state=$(auto_state)
  if [ "$state" = false ]; then
    echo "Auto-merge is no longer enabled on PR #$PR."
    return 0
  fi
  echo "::error::Failed to disable auto-merge on PR #$PR; it is still enabled."
  exit 1
}

if [ "${BASE:-}" != main ]; then
  echo "PR #$PR base is '${BASE:-unknown}', not main: stacked PRs are forbidden (#33)."
  disable_auto
  exit 0
fi

case "$ACTION" in
  opened | reopened | ready_for_review) ;;
  labeled)
    if [ "${LABEL:-}" != review:approved ]; then
      echo "Label '${LABEL:-}' does not enable auto-merge."
      exit 0
    fi
    ;;
  *)
    echo "Action '$ACTION' on a main PR does not enable auto-merge."
    exit 0
    ;;
esac
if [ "${DRAFT:-}" != false ]; then
  echo "PR #$PR is a draft (or its state is unknown): auto-merge not enabled."
  exit 0
fi
"$GH" pr merge "$PR" --auto --squash
