#!/usr/bin/env bash
# Enables squash auto-merge on a PR, only when its base is main (#33).
# The workflow job already filters on the base; this re-checks it.
#
# Required environment: PR (number), BASE (base ref from the event).
# GH can point to another gh binary; tests put a fake gh first in PATH.
set -euo pipefail

GH="${GH:-gh}"
: "${PR:?PR is required}"

if [ "${BASE:-}" != main ]; then
  echo "Skipping auto-merge: PR #$PR base is '${BASE:-unknown}', not main (#33)."
  exit 0
fi
"$GH" pr merge "$PR" --auto --squash
