#!/usr/bin/env bash
# Auto-merge policy for one PR (#18, #33). Fails closed on API errors.
# Base main: enable squash auto-merge on opened, reopened, ready_for_review
# or labeled review:approved, never on a draft and never on edited.
# Any other base (retarget included): disable auto-merge if it is enabled,
# because the main ruleset does not protect that base.
#
# Required environment: PR (number), ACTION (event action).
# Optional: BASE (base ref), DRAFT (true/false), LABEL (label name).
# GH can point to another gh binary; tests put a fake gh first in PATH.
set -euo pipefail

GH="${GH:-gh}"
: "${PR:?PR is required}" "${ACTION:?ACTION is required}"

disable_auto() {
  local state out
  if ! state=$("$GH" pr view "$PR" --json autoMergeRequest --jq '.autoMergeRequest != null'); then
    echo "::error::Cannot read the auto-merge state of PR #$PR."
    exit 1
  fi
  if [ "$state" = false ]; then
    echo "Auto-merge is not enabled on PR #$PR: nothing to disable."
    return 0
  fi
  if [ "$state" != true ]; then
    echo "::error::Unexpected auto-merge state '$state' for PR #$PR."
    exit 1
  fi
  if out=$("$GH" pr merge "$PR" --disable-auto 2>&1); then
    echo "Auto-merge disabled on PR #$PR."
    return 0
  fi
  case "$out" in
    *"not enabled"*)
      echo "Auto-merge was already disabled on PR #$PR." ;;
    *)
      echo "$out" >&2
      echo "::error::Failed to disable auto-merge on PR #$PR."
      exit 1
      ;;
  esac
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
