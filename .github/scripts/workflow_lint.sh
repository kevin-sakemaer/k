#!/usr/bin/env bash
# Hardened CI rules for every workflow (#6), run by tool/check.sh in the
# required `test` check:
# - every `uses:` is pinned by a full 40-character commit SHA, followed by the
#   version in a comment (`uses: owner/repo@<sha> # vX.Y.Z`);
# - every job sets `timeout-minutes`;
# - the workflow sets exactly `permissions: {}` at the top level; jobs widen
#   their own permissions.
# Usage: workflow_lint.sh [workflow-directory] (default .github/workflows).
set -euo pipefail

dir="${1:-.github/workflows}"
shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
[ "${#files[@]}" -gt 0 ] || { echo "workflow_lint: no workflow found in $dir" >&2; exit 1; }

errors=0
report() { echo "$1: $2" >&2; errors=$((errors + 1)); }

for f in "${files[@]}"; do
  while IFS=: read -r line text; do
    if ! [[ "$text" =~ ^[[:space:]-]*uses:[[:space:]]*[^[:space:]@#]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9] ]]; then
      report "$f:$line" "action not pinned by a full commit SHA with its version in a comment: ${text#"${text%%[![:space:]]*}"}"
    fi
  done < <(grep -nE '^[[:space:]-]*uses:' "$f" || true)

  grep -qxE 'permissions:[[:space:]]*\{\}[[:space:]]*' "$f" \
    || report "$f" "top-level permissions must be exactly 'permissions: {}'"

  # Job keys are the two-space keys under `jobs:`; each job block must contain
  # a four-space `timeout-minutes:` key.
  while read -r job; do
    report "$f" "job '$job' has no timeout-minutes"
  done < <(awk '
    /^[^[:space:]#]/ { flush(); in_jobs = ($0 ~ /^jobs:/); next }
    in_jobs && /^  [A-Za-z0-9_-]+:/ { flush(); job = $1; sub(/:$/, "", job); has = 0; next }
    in_jobs && job != "" && /^    timeout-minutes:/ { has = 1 }
    function flush() { if (job != "" && !has) print job; job = "" }
    END { flush() }
  ' "$f")
done

if [ "$errors" -gt 0 ]; then
  echo "workflow_lint: $errors problem(s) found." >&2
  exit 1
fi
echo "workflow_lint: ${#files[@]} workflow(s) pass."
