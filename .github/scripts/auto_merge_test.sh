#!/usr/bin/env bash
# Tests for auto_merge.sh, in plain bash, with a fake gh placed first in PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/auto_merge.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
MOCK
chmod +x "$WORK/bin/gh"

PASS=0
FAILED=0

# run_case NAME BASE EXPECTED_CALLS: runs the script with that base.
run_case() {
  export CALLS="$WORK/calls-$PASS-$FAILED"
  : >"$CALLS"
  local code=0
  OUT=$(PATH="$WORK/bin:$PATH" PR=21 BASE="$2" bash "$SCRIPT" 2>&1) || code=$?
  if [ "$code" = 0 ] && [ "$(cat "$CALLS")" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "ok   - $1"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL - $1 (exit $code)"
    printf '%s\n' "$OUT" | sed 's/^/       /'
  fi
}

run_case "base main enables auto-merge" main "pr merge 21 --auto --squash"
run_case "feature base is skipped" feat/k-config-10 ""
run_case "empty base is skipped" "" ""
run_case "main-like base is skipped" main2 ""

echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
