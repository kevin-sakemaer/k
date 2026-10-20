#!/usr/bin/env bash
# Tests for auto_merge.sh, in plain bash, with a fake gh placed first in PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/auto_merge.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# The fake gh logs its arguments to $CALLS. "pr view" prints $AUTO (true or
# false); VIEW_FAIL=1 makes it fail. "pr merge --disable-auto" fails with
# $DISABLE_ERR when it is set.
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$*" in
  "pr view"*)
    [ "${VIEW_FAIL:-0}" = 1 ] && { echo "gh: HTTP 502" >&2; exit 1; }
    echo "${AUTO:-false}" ;;
  *--disable-auto*)
    if [ -n "${DISABLE_ERR:-}" ]; then echo "$DISABLE_ERR" >&2; exit 1; fi ;;
esac
MOCK
chmod +x "$WORK/bin/gh"

PASS=0
FAILED=0
N=0

# run_case NAME EXPECTED_CODE EXPECTED_MERGE_CALL VAR=VALUE...: runs the
# script with the given environment; EXPECTED_MERGE_CALL is the only
# "pr merge" call expected ("" for none).
run_case() {
  local name="$1" want="$2" merge="$3" code=0 got
  shift 3
  N=$((N + 1))
  export CALLS="$WORK/calls-$N"
  : >"$CALLS"
  OUT=$(env PATH="$WORK/bin:$PATH" PR=21 ACTION=opened BASE=main DRAFT=false \
    "$@" bash "$SCRIPT" 2>&1) || code=$?
  got=$(grep '^pr merge' "$CALLS" || true)
  if { [ "$want" = 0 ] && [ "$code" = 0 ]; } || { [ "$want" != 0 ] && [ "$code" != 0 ]; }; then
    if [ "$got" = "$merge" ]; then
      PASS=$((PASS + 1))
      echo "ok   - $name"
      return
    fi
  fi
  FAILED=$((FAILED + 1))
  echo "FAIL - $name (exit $code, merge call '$got')"
  printf '%s\n' "$OUT" | sed 's/^/       /'
}

E="pr merge 21 --auto --squash"
D="pr merge 21 --disable-auto"

run_case "main opened enables" 0 "$E"
run_case "main reopened enables" 0 "$E" ACTION=reopened
run_case "main ready_for_review enables" 0 "$E" ACTION=ready_for_review
run_case "main labeled review:approved enables" 0 "$E" ACTION=labeled LABEL=review:approved
run_case "main other label is a no-op" 0 "" ACTION=labeled LABEL=ci
run_case "main draft is a no-op" 0 "" DRAFT=true
run_case "main unknown draft state is a no-op" 0 "" DRAFT=
run_case "main edited does not enable" 0 "" ACTION=edited
run_case "retarget main->feat/x disables" 0 "$D" ACTION=edited BASE=feat/x AUTO=true
run_case "draft retarget to feat/x disables" 0 "$D" ACTION=edited BASE=feat/x DRAFT=true AUTO=true
run_case "empty base disables (fail closed)" 0 "$D" BASE= AUTO=true
run_case "main-like base disables" 0 "$D" BASE=main2 AUTO=true
run_case "non-main without auto-merge is a no-op" 0 "" ACTION=edited BASE=feat/x AUTO=false
run_case "non-main labeled approved never enables" 0 "" ACTION=labeled LABEL=review:approved BASE=feat/x
run_case "disable 'not enabled' race is tolerated" 0 "$D" BASE=feat/x AUTO=true \
  DISABLE_ERR="GraphQL: Auto merge is not enabled for this pull request"
run_case "disable failure fails" 1 "$D" BASE=feat/x AUTO=true DISABLE_ERR="HTTP 502"
run_case "unreadable auto-merge state fails" 1 "" BASE=feat/x VIEW_FAIL=1

echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
