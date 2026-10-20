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
    --jq | -f) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  */pulls/*/files*) key=files ;;
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
  printf 'HTTP/2.0 %s\r\n\r\n' "$status"
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
# VM is V2 with lib/x.txt made executable. VSA adds lib/s as a file
# and VSB (rebased) as a symlink with the same content.
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
  git -C "$o" checkout -q -b vm "$V2"
  chmod +x "$o/lib/x.txt"
  git -C "$o" commit -qam vm
  VM=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b vsa "$V1"
  printf 'target' >"$o/lib/s"
  git -C "$o" add -A && git -C "$o" commit -qm vsa
  VSA=$(git -C "$o" rev-parse HEAD)
  git -C "$o" checkout -q -b vsb "$V2"
  ln -s target "$o/lib/s"
  git -C "$o" add -A && git -C "$o" commit -qm vsb
  VSB=$(git -C "$o" rev-parse HEAD)
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
  printf '%s\tkevin-sakemaer/k\tfeature\t%s\tmain\n' "${HEAD:-AAAA}" "$count" >"$MOCK/pulls.out"
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
  OUT=$(PATH="$WORK/bin:$PATH" K_GATE_TEST=1 GATE_GIT_URL="${GATE_GIT_URL:-$WORK/no-such-repo}" REPO=kevin-sakemaer/k PR=8 bash "$SCRIPT" 2>&1)
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

for p in tool/check.sh tool/check_test.sh tool/hooks/pre-push analysis_options.yaml k.yaml; do
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

for p in dart_test.yaml packages/k_core/dart_test.yaml a/b/c/dart_test.yaml; do
  new_case "$p (skip/exclude tags) without label fails" opened "$p lib/a.dart"
  check 1 "  $p"
done

new_case "renaming away a nested dart_test.yaml without label fails" opened "packages/k_core/old.yaml:packages/k_core/dart_test.yaml"
check 1 "  packages/k_core/dart_test.yaml"

new_case "renaming to a nested dart_test.yaml without label fails" opened "packages/x/dart_test.yaml:foo.yaml"
check 1 "  packages/x/dart_test.yaml"

# GitHub lists a deleted file under its own name, like a modified one.
new_case "deleting a nested dart_test.yaml without label fails" opened "packages/x/dart_test.yaml"
check 1 "  packages/x/dart_test.yaml"

new_case "nested dart_test.yaml with fresh label passes" labeled "packages/k_core/dart_test.yaml" "$L"
fresh
check 0 "Approved by label" kept

new_case "nested dart_test.yaml with stale label fails" synchronize "packages/k_core/dart_test.yaml" "$L"
check 1 "the Reviewer must add the label" deleted

new_case "similar test config files are not protected" opened "dart_test.yaml.bak docs/dart_test.yaml.md packages/a/my_dart_test.yaml test/dart_test_helper.dart"
check 0 "No protected path changed."

new_case "other tool files are not protected" opened "tool/install_hooks.sh"
check 0 "No protected path changed."

for p in packages/k_comments/lib/src/check.dart packages/k_config/lib/k_config.dart packages/k_publishers/bin/k_publishers.dart packages/k_workflows/pubspec.yaml; do
  new_case "checker package file $p without label fails" opened "$p lib/a.dart"
  check 1 "  $p"
done

new_case "checker package with fresh label passes" labeled "packages/k_config/lib/src/parser.dart" "$L"
fresh
check 0 "Approved by label" kept

new_case "deleting a checker package test without label fails" opened "packages/k_comments/test/cli_test.dart"
check 1 "  packages/k_comments/test/cli_test.dart"

new_case "renaming a file out of a checker package without label fails" opened "packages/other/a.dart:packages/k_publishers/lib/a.dart"
check 1 "  packages/k_publishers/lib/a.dart"

new_case "renaming a file into a checker package without label fails" opened "packages/k_config/lib/a.dart:packages/other/a.dart"
check 1 "  packages/k_config/lib/a.dart"

for p in pubspec.yaml pubspec.lock pubspec_overrides.yaml packages/k_comments/pubspec_overrides.yaml packages/k_config/pubspec_overrides.yaml packages/k_publishers/pubspec_overrides.yaml packages/k_workflows/pubspec_overrides.yaml packages/k_core/pubspec_overrides.yaml packages/other/pubspec_overrides.yaml a/b/c/pubspec_overrides.yaml packages/k_core/pubspec.lock packages/other/pubspec.lock a/b/c/pubspec.lock packages/k_core/pubspec.yaml packages/other/pubspec.yaml a/b/pubspec.yaml; do
  new_case "dependency resolution file $p without label fails" opened "$p"
  check 1 "  $p"
done

# The guard matches paths, not content: a non-checker member pubspec.yaml whose
# diff adds dependency_overrides (applied to the whole workspace, so to the
# checkers too) is refused without the label, whatever the diff contains.
new_case "dependency_overrides added in packages/k_core/pubspec.yaml without label fails" opened "packages/k_core/pubspec.yaml"
check 1 "  packages/k_core/pubspec.yaml" kept

new_case "a new workspace package without label fails" opened "packages/k_new/pubspec.yaml packages/k_new/lib/k_new.dart"
check 1 "  packages/k_new/pubspec.yaml"

new_case "names similar to pubspec files are not protected" opened "docs/pubspec.yaml.md packages/k_core/pubspec.yaml.bak packages/a/my_pubspec.yaml pubspec.yaml.bak pubspec.lock.bak packages/a/my_pubspec.lock packages/a/pubspec_overrides.yaml.bak"
check 0 "No protected path changed."

new_case "packages outside the checker list are not protected" opened "packages/k_core/lib/k_core.dart packages/other/lib/a.dart"
check 0 "No protected path changed."

new_case "misleading checker prefixes are not protected" opened "packages/k_config_extra/lib/a.dart packages/k_comments2/a.dart packages/k_publishers.md packages/k_workflows_old/x.dart other/packages/k_config/a.dart"
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

# Completeness of CHECKER_PACKAGES, read from the script itself. Criterion: a
# package is a checker when it has a bin/ directory (tool/check.sh and the
# workflows run checkers as packages/<name>/bin/<name>.dart), and every
# packages/k_* is a checker unless it is in NON_CHECKERS below, an explicit
# list of libraries without any executable. Every bin/ script that
# tool/check.sh or a workflow runs must also belong to a listed package, and
# every listed package must exist.
NON_CHECKERS=(packages/k_core)
ROOT="$(cd "$HERE/../.." && pwd)"
LISTED=$(sed -n '/^CHECKER_PACKAGES=(/,/^)/{/^ /p}' "$SCRIPT" | tr -d ' ')
listed() { printf '%s\n' "$LISTED" | grep -qxF "$1"; }
non_checker() { printf '%s\n' "${NON_CHECKERS[@]}" | grep -qxF "$1"; }
missing=""
for d in "$ROOT"/packages/*/; do
  pkg="packages/$(basename "$d")"
  if [ -d "$d/bin" ] && ! listed "$pkg"; then missing+=" $pkg(bin)"; fi
  case "$pkg" in
    packages/k_*) if ! non_checker "$pkg" && ! listed "$pkg"; then missing+=" $pkg"; fi ;;
  esac
done
for pkg in $(grep -ohE 'packages/[A-Za-z0-9_]+/bin/' "$ROOT/tool/check.sh" "$ROOT"/.github/workflows/*.yml | sed 's#/bin/##' | sort -u); do
  if ! listed "$pkg"; then missing+=" $pkg(run)"; fi
done
for pkg in $LISTED; do
  if [ ! -d "$ROOT/$pkg" ]; then missing+=" $pkg(absent)"; fi
done
for pkg in "${NON_CHECKERS[@]}"; do
  if [ -d "$ROOT/$pkg/bin" ]; then missing+=" $pkg(non-checker with bin)"; fi
done
if [ -z "$missing" ] && [ -n "$LISTED" ]; then
  PASS=$((PASS + 1))
  echo "ok   - CHECKER_PACKAGES lists every checker package"
else
  FAILED=$((FAILED + 1))
  echo "FAIL - CHECKER_PACKAGES lists every checker package:${missing:- empty list}"
fi

# Same-patch rule (#52), with real git objects from the local origin.
# rebase_case NAME ACTION APPROVED HEAD FILES: label added at 10:00 while
# APPROVED was the head (pushed 09:00); HEAD pushed at 11:00.
rebase_case() {
  HEAD="$4" new_case "$1" "$2" "$5" "$L"
  echo "labeled $L 2026-10-20T10:00:00Z" >"$MOCK/timeline.out"
  printf '%s 2026-10-20T09:00:00Z\n%s 2026-10-20T11:00:00Z\n' "$3" "$4" >"$MOCK/activity.out"
  export GATE_GIT_URL="$ORIGIN"
}
# real_mismatch: both patch-ids were computed and differ (not an error).
real_mismatch() {
  if [ "$(grep -c '^Patch-id (stable verbatim) at .*: [0-9a-f]\{40\} [0-9a-f]\{40\}$' <<<"$OUT")" != 2 ]; then
    FAILED=$((FAILED + 1)); echo "FAIL - $CASE (patch-ids not both computed)"
  fi
}
no_marker() {
  if grep -q 'issues/8/comments' "$MOCK/calls"; then
    FAILED=$((FAILED + 1)); echo "FAIL - $CASE (marker comment written)"
  fi
}

rebase_case "same patch after rebase keeps the label" synchronize "$V1" "$V2" ".github/w.yml lib/x.txt"
check 0 "Approved by label $L (same patch as the approved SHA)." kept
case "$OUT" in *"Protected paths changed:"*".github/w.yml"*) ;; *) FAILED=$((FAILED + 1)); echo "FAIL - $CASE (protected path not listed)" ;; esac
if ! grep -q "POST repos/kevin-sakemaer/k/issues/8/comments -f body=<!-- k-gate:approved-by-rebase label=$L sha=$V2 from=$V1 patch-id=" "$MOCK/calls"; then
  FAILED=$((FAILED + 1)); echo "FAIL - $CASE (no approved-by-rebase marker)"
fi

rebase_case "same patch: later label run still passes" labeled "$V1" "$V2" ".github/w.yml lib/x.txt"
check 0 "(same patch as the approved SHA)" kept
no_marker

rebase_case "changed patch removes the label and fails" synchronize "$V1" "$V3" ".github/w.yml lib/x.txt"
check 1 "the Reviewer must add the label" deleted
no_marker

rebase_case "added protected file after rebase removes the label" synchronize "$V1" "$VP" ".github/new.yml .github/w.yml lib/x.txt"
check 1 "  .github/new.yml" deleted

rebase_case "changed patch on a later label run removes the label" labeled "$V1" "$V3" ".github/w.yml lib/x.txt"
check 1 "$L predates the latest push" deleted

rebase_case "whitespace-only change in a protected file removes the label" synchronize "$V1" "$V4" ".github/w.yml lib/x.txt"
check 1 "the Reviewer must add the label" deleted
real_mismatch

rebase_case "empty diff on both sides removes the label" synchronize "$E0" "$E1" ""
check 0 "No protected path changed." deleted

rebase_case "missing approval record removes the label" synchronize "$V1" "$V2" ".github/w.yml"
: >"$MOCK/timeline.out"
check 1 "the Reviewer must add the label" deleted

rebase_case "activity API error removes the label" synchronize "$V1" "$V2" ".github/w.yml"
echo 500 >"$MOCK/activity.status"
check 1 "the Reviewer must add the label" deleted

rebase_case "fetch error removes the label" synchronize "$V1" "$V2" ".github/w.yml"
export GATE_GIT_URL="$WORK/no-such-repo"
check 1 "the Reviewer must add the label" deleted

rebase_case "marker comment error removes the label" synchronize "$V1" "$V2" ".github/w.yml"
echo 500 >"$MOCK/comments.status"
check 1 "Could not write the approved-by-rebase marker comment" deleted

rebase_case "fork head with the same patch removes the label" synchronize "$V1" "$V2" ".github/w.yml lib/x.txt"
printf '%s\tsomeone/k\tfeature\t2\tmain\n' "$V2" >"$MOCK/pulls.out"
check 1 "(fork): drop" deleted
no_marker

rebase_case "same-repository head with the same patch keeps the label" synchronize "$V1" "$V2" ".github/w.yml lib/x.txt"
check 0 "same patch: keep" kept

rebase_case "mode change (+x) removes the label" synchronize "$V1" "$VM" ".github/w.yml lib/x.txt"
check 1 "the Reviewer must add the label" deleted
real_mismatch

rebase_case "file replaced by a symlink removes the label" synchronize "$VSA" "$VSB" ".github/w.yml lib/s lib/x.txt"
check 1 "the Reviewer must add the label" deleted
real_mismatch

rebase_case "malformed push time removes the label" synchronize "$V1" "$V2" ".github/w.yml"
printf '%s 2026-10-20T09:00:00.123Z\n%s 2026-10-20T11:00:00Z\n' "$V1" "$V2" >"$MOCK/activity.out"
check 1 "Malformed push time" deleted

rebase_case "malformed label time removes the label" synchronize "$V1" "$V2" ".github/w.yml"
echo "labeled $L 2026-10-20T10:00:00+02:00" >"$MOCK/timeline.out"
check 1 "Malformed label time" deleted

# Injected git config must not reach bare_git (shared from freshness.sh):
# each variable redirects the fetch of $ORIGIN to a missing repository, so
# honoring it would drop the label.
printf '[url "%s/nowhere"]\n\tinsteadOf = %s\n' "$WORK" "$ORIGIN" >"$WORK/redirect.gitconfig"
for inject in count parameters global system; do
  rebase_case "injected git config ($inject) is ignored" synchronize "$V1" "$V2" ".github/w.yml lib/x.txt"
  case "$inject" in
    count) set -- GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=url.$WORK/nowhere.insteadOf" "GIT_CONFIG_VALUE_0=$ORIGIN" ;;
    parameters) set -- "GIT_CONFIG_PARAMETERS='url.$WORK/nowhere.insteadof'='$ORIGIN'" ;;
    global) set -- "GIT_CONFIG_GLOBAL=$WORK/redirect.gitconfig" ;;
    system) set -- "GIT_CONFIG_SYSTEM=$WORK/redirect.gitconfig" ;;
  esac
  # check runs the script itself: export the injected variables around it.
  export "$@"
  check 0 "same patch: keep" kept
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
done
set --

rebase_case "reopened with the same patch still removes the label" reopened "$V1" "$V2" ".github/w.yml"
check 1 "the Reviewer must add the label" deleted
no_marker
unset GATE_GIT_URL

echo "github_guard: $PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
