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
include=0 endpoint=""
shift # "api"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    -i | --include) include=1; shift ;;
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
  */timeline*) key=timeline ;;
  */activity*) key=activity ;;
  */actions/runs*) key=runs ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 99 ;;
esac
status=200
if [ -f "$MOCK/$key.status" ]; then status=$(cat "$MOCK/$key.status"); fi
if [ "$include" = 1 ]; then
  printf 'HTTP/2.0 %s\r\n\r\n' "$status"
fi
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
N=0
L=ci:github-change-approved

# new_case NAME ACTION FILES LABELS...: FILES is a space-separated list; a
# rename is written NEW:OLD.
new_case() {
  CASE="$1"
  export ACTION="$2"
  local files="$3" f count=0
  shift 3
  N=$((N + 1))
  export MOCK="$WORK/$N"
  mkdir -p "$MOCK"
  : >"$MOCK/files.out"
  for f in $files; do
    count=$((count + 1))
    case "$f" in
      *:*) printf '%s\t%s\n' "${f%%:*}" "${f#*:}" >>"$MOCK/files.out" ;;
      *) printf '%s\t\n' "$f" >>"$MOCK/files.out" ;;
    esac
  done
  printf 'AAAA\tkevin-sakemaer/k\tfeature\t%s\n' "$count" >"$MOCK/pulls.out"
  printf '%s\n' "$@" >"$MOCK/labels.out"
  : >"$MOCK/timeline.out"
  : >"$MOCK/activity.out"
  : >"$MOCK/runs.out"
  : >"$MOCK/calls"
}

# fresh: the label was added after the head push.
fresh() {
  echo "labeled $L 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
  echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
}

# check EXPECTED_CODE EXPECTED_TEXT [deleted|kept]
check() {
  set +e
  OUT=$(PATH="$WORK/bin:$PATH" REPO=kevin-sakemaer/k PR=8 bash "$SCRIPT" 2>&1)
  CODE=$?
  set -e
  local ok=1
  [ "$CODE" = "$1" ] || ok=0
  case "$OUT" in *"$2"*) ;; *) ok=0 ;; esac
  if [ "${3:-}" = deleted ] && ! grep -q -- '-X DELETE' "$MOCK/calls"; then ok=0; fi
  if [ "${3:-}" = kept ] && grep -q -- '-X DELETE' "$MOCK/calls"; then ok=0; fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1))
    echo "ok   - $CASE"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL - $CASE (exit $CODE, expected $1 / '$2')"
    printf '%s\n' "$OUT" | sed 's/^/       /'
  fi
}

new_case "no protected change passes" opened "lib/a.dart README.md"
check 0 "No protected path changed." kept

new_case "workflow change without label fails" opened ".github/workflows/x.yml lib/a.dart" ci
check 1 "the Reviewer must add the label" kept

new_case "script change without label fails" labeled ".github/scripts/review_gate.sh"
check 1 ".github/scripts/review_gate.sh"

for p in tool/check.sh tool/check_test.sh tool/hooks/pre-push packages/k_comments/lib/src/scanner.dart packages/k_comments/pubspec.yaml analysis_options.yaml k.yaml; do
  new_case "$p is protected" opened "$p"
  check 1 "  $p"
done

for p in packages/k_core/analysis_options.yaml a/b/analysis_options.yaml packages/a/k.yaml; do
  new_case "nested $p without label fails" opened "$p"
  check 1 "  $p"
done

new_case "nested analysis_options.yaml with fresh label passes" labeled "packages/k_core/analysis_options.yaml" "$L"
fresh
check 0 "Approved by label" kept

new_case "similar analysis files are not protected" opened "analysis_options.yaml.bak docs/analysis_options.md packages/a/my_analysis_options.yaml packages/a/k.yaml.bak"
check 0 "No protected path changed."

new_case "other tool files are not protected" opened "tool/install_hooks.sh packages/k_core/lib/k_core.dart packages/k_comments_extra/x.dart"
check 0 "No protected path changed."

new_case "fresh label passes" labeled ".github/CODEOWNERS" "$L"
fresh
check 0 "Approved by label" kept

new_case "label older than head push fails and is removed" labeled ".github/x" "$L"
echo "labeled $L 2026-10-20T08:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
check 1 "predates the latest push" deleted

new_case "edited run right after a push is refused" edited ".github/x" "$L"
echo "labeled $L 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T10:00:00Z" >"$MOCK/activity.out"
check 1 "predates the latest push" deleted

new_case "synchronize DELETE failed, then labeled run is refused" labeled ".github/x" "$L" owner:dev1
printf '%s\n' "labeled $L 2026-10-20T08:00:00Z" "labeled owner:dev1 2026-10-20T09:00:30Z" >"$MOCK/timeline.out"
echo "AAAA 2026-10-20T09:00:00Z" >"$MOCK/activity.out"
check 1 "predates the latest push" deleted

new_case "label without push time fails" labeled ".github/x" "$L"
echo "labeled $L 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
check 1 "predates the latest push" deleted

new_case "activity 404 uses the fallback" labeled ".github/x" "$L"
echo 404 >"$MOCK/activity.status"
echo "labeled $L 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
echo "2026-10-20T09:00:00Z" >"$MOCK/runs.out"
check 0 "source: fallback" kept

new_case "activity 500 fails without fallback" labeled ".github/x" "$L"
echo 500 >"$MOCK/activity.status"
fresh
check 1 "Activity API failed (HTTP 500)." kept

new_case "timeline API error fails closed" labeled ".github/x" "$L"
echo 500 >"$MOCK/timeline.status"
check 1 "GitHub API call failed" kept

new_case "synchronize removes label and fails" synchronize ".github/x" "$L"
fresh
check 1 "removed after a new push" deleted

new_case "reopened removes label and fails" reopened ".github/x" "$L"
fresh
check 1 "the Reviewer must add the label" deleted

new_case "synchronize removes label without protected change" synchronize "lib/a.dart" "$L"
check 0 "No protected path changed." deleted

new_case "rename out of .github is protected" opened "tool/x.sh:.github/x.sh"
check 1 ".github/x.sh"

new_case "similar names are not protected" opened "github/x .githubx/y docs/.github"
check 0 "No protected path changed."

new_case "truncated file listing fails closed" opened "lib/a.dart lib/b.dart"
printf 'AAAA\tkevin-sakemaer/k\tfeature\t3\n' >"$MOCK/pulls.out"
check 1 "the listing is incomplete"

new_case "files API error fails closed" opened "lib/a.dart"
echo 500 >"$MOCK/files.status"
check 1 "GitHub API call failed"

new_case "labels API error fails closed" opened "lib/a.dart"
echo 502 >"$MOCK/labels.status"
check 1 "GitHub API call failed"

new_case "unreadable file count fails closed" opened "lib/a.dart"
printf 'AAAA\tkevin-sakemaer/k\tfeature\tnull\n' >"$MOCK/pulls.out"
check 1 "Could not read the number of changed files."

new_case "too many files fails closed" opened "lib/a.dart"
printf 'AAAA\tkevin-sakemaer/k\tfeature\t3000\n' >"$MOCK/pulls.out"
check 1 "cannot list them all"

new_case "label removal forbidden fails" synchronize "lib/a.dart" "$L"
echo 403 >"$MOCK/delete.status"
check 1 "read-only token"

new_case "label already gone is fine" synchronize "lib/a.dart" "$L"
echo 404 >"$MOCK/delete.status"
check 0 "No protected path changed."

echo "github_guard: $PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
