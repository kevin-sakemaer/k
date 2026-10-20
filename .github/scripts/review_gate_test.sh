#!/usr/bin/env bash
# Tests for review_gate.sh, in plain bash, with a fake gh placed first in PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/review_gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# The fake gh answers from files in $MOCK: <key>.out is the output (already
# filtered as --jq would) and <key>.status an HTTP status (default 200).
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK/calls"
method=GET include=0 endpoint=""
shift # "api"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -i | --include) include=1; shift ;;
    --paginate) shift ;;
    --jq) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  */pulls/*) key=pulls ;;
  */labels/*) key=delete ;;
  */labels) key=labels ;;
  */timeline*) key=timeline ;;
  */activity*) key=activity ;;
  */actions/runs*) key=runs ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 99 ;;
esac
status=200
if [ -f "$MOCK/$key.status" ]; then status=$(cat "$MOCK/$key.status"); fi
if [ "$include" = 1 ]; then printf 'HTTP/2.0 %s\r\n\r\n' "$status"; fi
if [ "$status" != 200 ]; then
  echo "gh: error (HTTP $status)" >&2
  exit 1
fi
if [ "$include" = 0 ] && [ -f "$MOCK/$key.out" ]; then cat "$MOCK/$key.out"; fi
MOCK
chmod +x "$WORK/bin/gh"

PASS=0
FAILED=0
CASE=""

# new_case NAME ACTION LABELS...: resets the fake API for a new scenario.
new_case() {
  CASE="$1"
  export ACTION="$2"
  shift 2
  export MOCK="$WORK/$CASE"
  mkdir -p "$MOCK"
  printf 'AAAA\tkevin-sakemaer/k\tfeature\n' >"$MOCK/pulls.out"
  printf '%s\n' "$@" >"$MOCK/labels.out"
  : >"$MOCK/timeline.out"
  : >"$MOCK/activity.out"
  : >"$MOCK/runs.out"
  : >"$MOCK/calls"
}

run_gate() {
  set +e
  OUT=$(PATH="$WORK/bin:$PATH" REPO=kevin-sakemaer/k PR=8 bash "$SCRIPT" 2>&1)
  CODE=$?
  set -e
}

check() {
  # check EXPECTED_CODE EXPECTED_TEXT [deleted|kept]
  local ok=1
  if [ "$1" = 0 ] && [ "$CODE" != 0 ]; then ok=0; fi
  if [ "$1" != 0 ] && [ "$CODE" = 0 ]; then ok=0; fi
  case "$OUT" in *"$2"*) ;; *) ok=0 ;; esac
  if [ "${3:-}" = deleted ] && ! grep -q -- '-X DELETE' "$MOCK/calls"; then ok=0; fi
  if [ "${3:-}" = kept ] && grep -q -- '-X DELETE' "$MOCK/calls"; then ok=0; fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1))
    echo "ok   - $CASE"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL - $CASE (exit $CODE)"
    printf '%s\n' "$OUT" | sed 's/^/       /'
  fi
}

new_case "label missing" labeled ci
run_gate
check 1 "Waiting for review: label review:approved is missing" kept

new_case "changes requested" labeled review:approved review:changes-requested
run_gate
check 1 "Label review:changes-requested is present." kept

new_case "synchronize removes approval" synchronize review:approved
run_gate
check 1 "review:approved removed after a new push; a new review is required" deleted

new_case "synchronize without approval" synchronize ci
run_gate
check 1 "Waiting for review: label review:approved is missing" kept

new_case "fresh approval passes" labeled review:approved
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 0 "Review approved." kept

new_case "A-B-A: approval given on B is refused for A" labeled review:approved
printf '%s\n' "AAAA 2026-10-20T09:00:00Z" "BBBB 2026-10-20T10:00:00Z" "AAAA 2026-10-20T11:00:00Z" >"$MOCK/activity.out"
printf '%s\n' "labeled review:approved 2026-10-20T10:30:00Z" "head_ref_force_pushed - 2026-10-20T11:00:00Z" >"$MOCK/timeline.out"
run_gate
check 1 "review:approved predates the latest push; a new review is required" deleted

new_case "A-B-A with fallback is refused" labeled review:approved
echo 404 >"$MOCK/activity.status"
printf '%s\n' "labeled review:approved 2026-10-20T10:30:00Z" "head_ref_force_pushed - 2026-10-20T11:00:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:05Z" >"$MOCK/runs.out"
run_gate
check 1 "review:approved predates the latest push" deleted

new_case "timestamp tie is refused" labeled review:approved
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T10:00:00Z" >"$MOCK/activity.out"
run_gate
check 1 "review:approved predates the latest push" deleted

new_case "empty approval time fails" labeled review:approved
echo "AAAA 2026-10-20T10:00:00Z" >"$MOCK/activity.out"
run_gate
check 1 "review:approved predates the latest push" deleted

new_case "empty push time fails" labeled review:approved
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "BBBB 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 1 "review:approved predates the latest push" deleted

new_case "activity 500 fails without fallback" labeled review:approved
echo 500 >"$MOCK/activity.status"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
run_gate
check 1 "Activity API failed (HTTP 500)." kept
if grep -q 'actions/runs' "$MOCK/calls"; then
  FAILED=$((FAILED + 1)); echo "FAIL - $CASE (fallback was used)"
fi

new_case "activity 404 allows fallback" labeled review:approved
echo 404 >"$MOCK/activity.status"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
run_gate
check 0 "source: fallback" kept

new_case "activity 403 allows fallback" labeled review:approved
echo 403 >"$MOCK/activity.status"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
run_gate
check 0 "Review approved." kept

new_case "fallback runs API error fails" labeled review:approved
echo 404 >"$MOCK/activity.status"
echo 502 >"$MOCK/runs.status"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
run_gate
check 1 "GitHub API call failed" kept

new_case "timeline API error fails" labeled review:approved
echo 500 >"$MOCK/timeline.status"
run_gate
check 1 "GitHub API call failed" kept

new_case "labels API error fails" labeled review:approved
echo 500 >"$MOCK/labels.status"
run_gate
check 1 "GitHub API call failed" kept

new_case "label removed already (404) on synchronize" synchronize review:approved
echo 404 >"$MOCK/delete.status"
run_gate
check 1 "review:approved removed after a new push" deleted

new_case "label removal forbidden (403)" synchronize review:approved
echo 403 >"$MOCK/delete.status"
run_gate
check 1 "read-only token" deleted

echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
