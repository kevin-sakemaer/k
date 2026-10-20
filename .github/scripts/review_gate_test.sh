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
    --jq | -f) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  */pulls/*) key=pulls ;;
  */labels/*) key=delete ;;
  */issues/*/comments) key=comments ;;
  */labels) key=labels ;;
  */timeline*) key=timeline ;;
  */activity*) key=activity ;;
  */actions/runs*) key=runs ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 99 ;;
esac
status=200
if [ -f "$MOCK/$key.status" ]; then status=$(cat "$MOCK/$key.status"); fi
if [ "$include" = 1 ]; then
  printf 'HTTP/2.0 %s\r\n' "$status"
  if [ -f "$MOCK/$key.headers" ]; then cat "$MOCK/$key.headers"; fi
  printf '\r\n'
  if [ -f "$MOCK/$key.body" ]; then cat "$MOCK/$key.body"; fi
fi
if [ "$status" != 200 ]; then
  echo "gh: error (HTTP $status)" >&2
  exit 1
fi
if [ "$include" = 0 ] && [ -f "$MOCK/$key.out" ]; then cat "$MOCK/$key.out"; fi
MOCK
chmod +x "$WORK/bin/gh"

# Same-patch fixture (#52): a local origin repository with real commits.
# main: C0 then C1 (unrelated). V1 is the approved head, branched from C0.
# V2 rebases V1 onto C1 (same patch). V3 resolves a conflict differently
# (changed patch). V4 only changes whitespace. V5A and V5B are V1 and V2
# with different binary contents.
# E0 and E1 have an empty diff from main. VP adds a protected file.
make_origin() {
  local o="$WORK/origin"
  # A git hook sets GIT_DIR and GIT_INDEX_FILE: never touch that repository.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_AUTHOR_DATE='2026-01-01T00:00:00Z'
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
  git init -q -b main "$o"
  git -C "$o" config uploadpack.allowAnySHA1InWant true
  mkdir -p "$o/.github" "$o/lib"
  printf 'a: 1\n' >"$o/.github/w.yml"
  printf 'one\ntwo\n' >"$o/lib/x.txt"
  printf '\000\001a' >"$o/lib/b.bin"
  printf 'base\n' >"$o/README.md"
  git -C "$o" add -A && git -C "$o" commit -qm c0
  local c0; c0=$(git -C "$o" rev-parse HEAD)
  E0=$c0
  git -C "$o" checkout -q -b v1
  printf 'one\ntwo\nthree\n' >"$o/lib/x.txt"
  printf 'a: 1\nb:\n  c: 2\n' >"$o/.github/w.yml"
  git -C "$o" commit -qam v1
  V1=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q main
  printf 'base\nmore\n' >"$o/README.md"
  git -C "$o" commit -qam c1
  E1=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b v2
  git -C "$o" cherry-pick "$V1" >/dev/null
  V2=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b v3 main
  printf 'one\ntwo\nTHREE\n' >"$o/lib/x.txt"
  printf 'a: 1\nb:\n  c: 2\n' >"$o/.github/w.yml"
  git -C "$o" commit -qam v3
  V3=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b v4 main
  printf 'one\ntwo\nthree\n' >"$o/lib/x.txt"
  printf 'a: 1\nb:\nc: 2\n' >"$o/.github/w.yml"
  git -C "$o" commit -qam v4
  V4=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b v5a "$V1"
  printf '\000\001c' >"$o/lib/b.bin"
  git -C "$o" commit -qam v5a
  V5A=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b v5b "$V2"
  printf '\000\001d' >"$o/lib/b.bin"
  git -C "$o" commit -qam v5b
  V5B=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b vp "$V2"
  printf 'x\n' >"$o/.github/new.yml"
  git -C "$o" add -A && git -C "$o" commit -qm vp
  VP=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q main
  ORIGIN="$o"
}
make_origin

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
  printf 'AAAA\tkevin-sakemaer/k\tfeature\tfalse\tmain\n' >"$MOCK/pulls.out"
  printf '%s\n' "$@" >"$MOCK/labels.out"
  : >"$MOCK/timeline.out"
  : >"$MOCK/activity.out"
  : >"$MOCK/runs.out"
  : >"$MOCK/calls"
}

run_gate() {
  set +e
  OUT=$(PATH="$WORK/bin:$PATH" GATE_GIT_URL="${GATE_GIT_URL:-$WORK/no-such-repo}" REPO=kevin-sakemaer/k PR=8 bash "$SCRIPT" 2>&1)
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

new_case "reopened removes approval" reopened review:approved
run_gate
check 1 "review:approved removed after a new push; a new review is required" deleted

new_case "B approved, closed, force-pushed to A, reopened, activity 404" labeled review:approved
echo 404 >"$MOCK/activity.status"
printf '%s\n' "labeled review:approved 2026-10-20T10:00:00Z" "closed - 2026-10-20T10:10:00Z" "reopened - 2026-10-20T10:30:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
run_gate
check 1 "review:approved predates the latest push" deleted

new_case "head_ref_restored after approval is refused" labeled review:approved
echo 404 >"$MOCK/activity.status"
printf '%s\n' "labeled review:approved 2026-10-20T10:00:00Z" "head_ref_restored - 2026-10-20T10:20:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
run_gate
check 1 "review:approved predates the latest push" deleted

for limit in "retry-after: 60" "x-ratelimit-remaining: 0" "message: API rate limit exceeded"; do
  new_case "rate-limit 403 ($limit) fails without fallback" labeled review:approved
  echo 403 >"$MOCK/activity.status"
  case "$limit" in
    message:*) printf '{"message":"API rate limit exceeded"}\n' >"$MOCK/activity.body" ;;
    *) printf '%s\r\n' "$limit" >"$MOCK/activity.headers" ;;
  esac
  echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
  echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
  run_gate
  check 1 "rate limited" kept
  if grep -q 'actions/runs' "$MOCK/calls"; then
    FAILED=$((FAILED + 1)); echo "FAIL - $CASE (fallback was used)"
  fi
done

new_case "access 403 with remaining quota allows fallback" labeled review:approved
echo 403 >"$MOCK/activity.status"
printf 'x-ratelimit-remaining: 4999\r\n' >"$MOCK/activity.headers"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
run_gate
check 0 "source: fallback" kept

new_case "missing shared freshness helper fails closed" labeled review:approved
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
mkdir -p "$WORK/nohelper"
cp "$SCRIPT" "$WORK/nohelper/review_gate.sh"
SAVED_SCRIPT="$SCRIPT"
SCRIPT="$WORK/nohelper/review_gate.sh"
run_gate
SCRIPT="$SAVED_SCRIPT"
check 1 "freshness.sh" kept

new_case "draft with fresh approval fails" labeled review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\ttrue\tmain\n' >"$MOCK/pulls.out"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 1 "PR is a draft" kept

new_case "converted_to_draft fails" converted_to_draft review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\ttrue\tmain\n' >"$MOCK/pulls.out"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 1 "PR is a draft" kept

new_case "draft without approval fails as draft" opened ci
printf 'AAAA\tkevin-sakemaer/k\tfeature\ttrue\tmain\n' >"$MOCK/pulls.out"
run_gate
check 1 "PR is a draft" kept

new_case "push on draft still removes approval" synchronize review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\ttrue\tmain\n' >"$MOCK/pulls.out"
run_gate
check 1 "review:approved removed after a new push" deleted

new_case "ready_for_review, not draft, fresh approval passes" ready_for_review review:approved
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 0 "Review approved." kept

new_case "ready_for_review, not draft, approval older than head push fails" ready_for_review review:approved
echo "labeled review:approved 2026-10-20T09:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T10:00:00Z" >"$MOCK/activity.out"
run_gate
check 1 "review:approved predates the latest push; a new review is required" deleted

# Stale payload: the event says converted_to_draft but the API reads draft
# false; the gate must follow the API.
new_case "converted_to_draft with API draft false follows the API" converted_to_draft review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\tfalse\tmain\n' >"$MOCK/pulls.out"
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 0 "Draft: false" kept
case "$OUT" in *"PR is a draft"*) FAILED=$((FAILED + 1)); echo "FAIL - $CASE (treated as draft)" ;; esac
case "$OUT" in *"Review approved."*) ;; *) FAILED=$((FAILED + 1)); echo "FAIL - $CASE (not approved)" ;; esac

new_case "unknown draft state fails closed" labeled review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\tnull\tmain\n' >"$MOCK/pulls.out"
run_gate
check 1 "Could not read the PR draft state." kept

new_case "base main passes" labeled review:approved
echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
run_gate
check 0 "Base: main" kept

new_case "stacked PR fails even when approved" labeled review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\tfalse\tfeat/k-config-10\n' >"$MOCK/pulls.out"
run_gate
check 1 "PR base is 'feat/k-config-10', not main: stacked PRs are forbidden" kept

new_case "missing base fails closed" labeled review:approved
printf 'AAAA\tkevin-sakemaer/k\tfeature\tfalse\n' >"$MOCK/pulls.out"
run_gate
check 1 "PR base is 'unknown', not main" kept

# Same-patch rule (#52): real git objects from the local origin.
# rebase_case NAME ACTION APPROVED HEAD: label added at 10:00 while APPROVED
# was the head (pushed 09:00); HEAD pushed at 11:00.
rebase_case() {
  new_case "$1" "$2" review:approved
  printf '%s\tkevin-sakemaer/k\tfeature\tfalse\tmain\n' "$4" >"$MOCK/pulls.out"
  echo "labeled review:approved 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
  printf '%s 2026-10-20T09:00:00Z\n%s 2026-10-20T11:00:00Z\n' "$3" "$4" >"$MOCK/activity.out"
}
run_rebase() {
  GATE_GIT_URL="$ORIGIN" run_gate
}
no_marker() {
  if grep -q 'issues/8/comments' "$MOCK/calls"; then
    FAILED=$((FAILED + 1)); echo "FAIL - $CASE (marker comment written)"
  fi
}

rebase_case "same patch after rebase keeps approval" synchronize "$V1" "$V2"
run_rebase
check 0 "same patch: keep" kept
case "$OUT" in *"Approved SHA for review:approved: $V1"*) ;; *) FAILED=$((FAILED + 1)); echo "FAIL - $CASE (approved SHA not logged)" ;; esac
if [ "$(grep -o 'Patch-id (stable verbatim) at [a-z0-9 ]*: [0-9a-f]\{40\} [0-9a-f]\{40\}' <<<"$OUT" | awk '{print $NF}' | sort -u | wc -l)" != 1 ]; then
  FAILED=$((FAILED + 1)); echo "FAIL - $CASE (both patch-ids not logged equal)"
fi
if ! grep -q "POST repos/kevin-sakemaer/k/issues/8/comments -f body=<!-- k-gate:approved-by-rebase label=review:approved sha=$V2 from=$V1 patch-id=" "$MOCK/calls"; then
  FAILED=$((FAILED + 1)); echo "FAIL - $CASE (no approved-by-rebase marker)"
fi

rebase_case "same patch: later label run still passes" labeled "$V1" "$V2"
run_rebase
check 0 "Review approved (same patch as the approved SHA)." kept
no_marker

rebase_case "same patch on a draft keeps the label but fails as draft" synchronize "$V1" "$V2"
printf '%s\tkevin-sakemaer/k\tfeature\ttrue\tmain\n' "$V2" >"$MOCK/pulls.out"
run_rebase
check 1 "PR is a draft" kept

rebase_case "same patch ignores the caller's GIT_DIR (git hook)" synchronize "$V1" "$V2"
GIT_DIR="$WORK/hook-git-dir" GIT_INDEX_FILE="$WORK/hook-index" GATE_GIT_URL="$ORIGIN" run_gate
check 0 "same patch: keep" kept
if [ -e "$WORK/hook-git-dir" ]; then FAILED=$((FAILED + 1)); echo "FAIL - $CASE (GIT_DIR used)"; fi

rebase_case "conflict resolution (changed patch) removes approval" synchronize "$V1" "$V3"
run_rebase
check 1 "review:approved removed after a new push" deleted
no_marker
case "$OUT" in *"patch differs or unknown: drop"*) ;; *) FAILED=$((FAILED + 1)); echo "FAIL - $CASE (decision not logged)" ;; esac

rebase_case "changed patch on a later label run removes approval" labeled "$V1" "$V3"
run_rebase
check 1 "review:approved predates the latest push" deleted

rebase_case "whitespace-only change removes approval" synchronize "$V1" "$V4"
run_rebase
check 1 "review:approved removed after a new push" deleted

rebase_case "binary content change removes approval" synchronize "$V5A" "$V5B"
run_rebase
check 1 "review:approved removed after a new push" deleted

rebase_case "empty diff on both sides removes approval" synchronize "$E0" "$E1"
run_rebase
check 1 "review:approved removed after a new push" deleted
case "$OUT" in *"Empty diff"*) ;; *) FAILED=$((FAILED + 1)); echo "FAIL - $CASE (empty diff not reported)" ;; esac

rebase_case "empty diff at head only removes approval" synchronize "$V1" "$E1"
run_rebase
check 1 "review:approved removed after a new push" deleted

rebase_case "missing approval record removes approval" synchronize "$V1" "$V2"
: >"$MOCK/timeline.out"
run_rebase
check 1 "no approval record: drop" deleted

rebase_case "no push before the label removes approval" synchronize "$V1" "$V2"
printf '%s 2026-10-20T11:00:00Z\n' "$V2" >"$MOCK/activity.out"
run_rebase
check 1 "approved SHA unknown: drop" deleted

rebase_case "push at the label time is ambiguous and removes approval" synchronize "$V1" "$V2"
printf '%s 2026-10-20T10:00:00Z\n%s 2026-10-20T11:00:00Z\n' "$V1" "$V2" >"$MOCK/activity.out"
run_rebase
check 1 "ambiguous approved SHA" deleted

rebase_case "activity API error removes approval" synchronize "$V1" "$V2"
echo 500 >"$MOCK/activity.status"
run_rebase
check 1 "review:approved removed after a new push" deleted

rebase_case "timeline API error removes approval" synchronize "$V1" "$V2"
echo 500 >"$MOCK/timeline.status"
run_rebase
check 1 "review:approved removed after a new push" deleted

rebase_case "fetch error removes approval" synchronize "$V1" "$V2"
run_gate
check 1 "review:approved removed after a new push" deleted

rebase_case "unknown approved commit removes approval" synchronize "$(printf 'f%.0s' {1..40})" "$V2"
run_rebase
check 1 "review:approved removed after a new push" deleted

rebase_case "marker comment error removes approval" synchronize "$V1" "$V2"
echo 500 >"$MOCK/comments.status"
run_rebase
check 1 "Could not write the approved-by-rebase marker comment" deleted

rebase_case "invalid head SHA removes approval" synchronize "$V1" "AAAA"
run_rebase
check 1 "head SHA or base branch unknown: drop" deleted

rebase_case "reopened with the same patch still removes approval" reopened "$V1" "$V2"
run_rebase
check 1 "review:approved removed after a new push" deleted
no_marker

echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
