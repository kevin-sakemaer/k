#!/usr/bin/env bash
# Tests of .github/scripts/workflow_lint.sh (#6).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lint="$here/workflow_lint.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
failed=0
sha=0123456789abcdef0123456789abcdef01234567

# expect <name> <exit: 0|1> <pattern> <workflow content>
expect() {
  local name="$1" want="$2" pattern="$3" d out code=0
  d="$(mktemp -d "$work/wf.XXXX")"
  printf '%s\n' "$4" >"$d/w.yml"
  out="$(bash "$lint" "$d" 2>&1)" || code=$?
  if { [ "$want" = 0 ] && [ "$code" = 0 ]; } || { [ "$want" = 1 ] && [ "$code" != 0 ]; }; then
    if grep -qF -- "$pattern" <<<"$out"; then
      echo "ok   - $name"; pass=$((pass + 1)); return
    fi
  fi
  echo "FAIL - $name (exit $code, expected '$pattern')"; sed 's/^/       /' <<<"$out"
  failed=$((failed + 1))
}

good="name: w
on: pull_request
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@$sha # v7.0.1
  b:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: true"

expect "a hardened workflow passes" 0 "1 workflow(s) pass" "$good"
expect "a tag reference fails" 1 "not pinned by a full commit SHA" \
  "${good/@$sha # v7.0.1/@v7}"
expect "a short SHA fails" 1 "not pinned by a full commit SHA" \
  "${good/@$sha/@0123456}"
expect "a SHA without version comment fails" 1 "not pinned by a full commit SHA" \
  "${good/ # v7.0.1/}"
expect "a job without timeout fails" 1 "job 'b' has no timeout-minutes" \
  "$(sed '12d' <<<"$good")"
expect "missing top-level permissions fails" 1 "missing top-level permissions" \
  "$(sed '/^permissions:/d' <<<"$good")"

d="$(mktemp -d "$work/empty.XXXX")"
out="$(bash "$lint" "$d" 2>&1)" && code=0 || code=$?
if [ "$code" != 0 ] && grep -qF "no workflow found" <<<"$out"; then
  echo "ok   - an empty directory fails"; pass=$((pass + 1))
else
  echo "FAIL - an empty directory fails"; failed=$((failed + 1))
fi

if bash "$lint" "$here/../workflows" >/dev/null 2>&1; then
  echo "ok   - the repository workflows pass"; pass=$((pass + 1))
else
  echo "FAIL - the repository workflows pass"; bash "$lint" "$here/../workflows" || true
  failed=$((failed + 1))
fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
