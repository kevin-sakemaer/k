#!/usr/bin/env bash
# Tests for github_guard.sh, in plain bash, with a fake gh placed first in PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/github_guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# The fake gh answers from files in $MOCK: <key>.out is the output (already
# filtered as --jq would) and <key>.status an HTTP status (default 200).
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$MOCK/calls"
endpoint=""
shift # "api"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    --paginate) shift ;;
    --jq) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  */pulls/*/files*) key=files ;;
  */pulls/*) key=pulls ;;
  */labels/*) key=delete ;;
  */labels) key=labels ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 99 ;;
esac
status=200
if [ -f "$MOCK/$key.status" ]; then status=$(cat "$MOCK/$key.status"); fi
if [ "$status" != 200 ]; then
  echo "gh: error (HTTP $status)" >&2
  exit 1
fi
if [ -f "$MOCK/$key.out" ]; then cat "$MOCK/$key.out"; fi
MOCK
chmod +x "$WORK/bin/gh"

PASS=0
FAILED=0
CASE=""

# new_case NAME ACTION FILES LABELS...: FILES is a space-separated list.
new_case() {
  CASE="$1"
  export ACTION="$2"
  local files="$3"
  shift 3
  export MOCK="$WORK/$PASS-$FAILED-${CASE// /_}"
  mkdir -p "$MOCK"
  printf '%s\n' $files >"$MOCK/files.out"
  printf '%s\n' "$(printf '%s\n' $files | grep -c .)" >"$MOCK/pulls.out"
  printf '%s\n' "$@" >"$MOCK/labels.out"
  : >"$MOCK/calls"
}

run_guard() {
  set +e
  OUT=$(PATH="$WORK/bin:$PATH" REPO=kevin-sakemaer/k PR=8 bash "$SCRIPT" 2>&1)
  CODE=$?
  set -e
}

# check EXPECTED_CODE EXPECTED_TEXT [deleted|kept]
check() {
  run_guard
  local ok=1
  [ "$CODE" = "$1" ] || ok=0
  printf '%s' "$OUT" | grep -qF -- "$2" || ok=0
  if [ "${3:-}" = deleted ]; then grep -q -- '-X DELETE' "$MOCK/calls" || ok=0; fi
  if [ "${3:-}" = kept ]; then ! grep -q -- '-X DELETE' "$MOCK/calls" || ok=0; fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1))
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: $CASE (code $CODE, expected $1 / '$2')"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
}

new_case "no protected change passes" opened "lib/a.dart README.md"
check 0 "No protected path changed." kept

new_case "workflow change without label fails" opened ".github/workflows/x.yml lib/a.dart" ci
check 1 "the Reviewer must add the label" kept

new_case "script change without label fails" labeled ".github/scripts/review_gate.sh"
check 1 ".github/scripts/review_gate.sh"

new_case "protected change with label passes" labeled ".github/CODEOWNERS" ci:github-change-approved
check 0 "Approved by label" kept

new_case "synchronize removes label and fails" synchronize ".github/x" ci:github-change-approved
check 1 "removed after a new push" deleted

new_case "reopened removes label and fails" reopened ".github/x" ci:github-change-approved
check 1 "the Reviewer must add the label" deleted

new_case "synchronize removes label without protected change" synchronize "lib/a.dart" ci:github-change-approved
check 0 "No protected path changed." deleted

new_case "rename out of .github is protected" opened "tool/x.sh .github/x.sh"
check 1 ".github/x.sh"

new_case "similar names are not protected" opened "github/x .githubx/y docs/.github"
check 0 "No protected path changed."

new_case "files API error fails closed" opened "lib/a.dart"
echo 500 >"$MOCK/files.status"
check 1 "GitHub API call failed"

new_case "labels API error fails closed" opened "lib/a.dart"
echo 502 >"$MOCK/labels.status"
check 1 "GitHub API call failed"

new_case "unreadable file count fails closed" opened "lib/a.dart"
echo null >"$MOCK/pulls.out"
check 1 "Could not read the number of changed files."

new_case "too many files fails closed" opened "lib/a.dart"
echo 3000 >"$MOCK/pulls.out"
check 1 "cannot list them all"

new_case "label removal forbidden fails" synchronize "lib/a.dart" ci:github-change-approved
echo 403 >"$MOCK/delete.status"
check 1 "read-only token"

new_case "label already gone is fine" synchronize "lib/a.dart" ci:github-change-approved
echo 404 >"$MOCK/delete.status"
check 0 "No protected path changed."

echo "github_guard: $PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
