#!/usr/bin/env bash
# Tests for closing_keywords.sh, in plain bash, with a fake gh placed first in
# PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/closing_keywords.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# The fake gh answers from files in $MOCK: <key>.out is the output (already
# filtered as --jq would) and <key>.status an HTTP status (default 200).
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
endpoint=""
shift # "api"
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  */pulls/*/commits*) key=commits ;;
  */pulls/*) key=pulls ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 99 ;;
esac
if [ -f "$MOCK/$key.status" ]; then
  echo "gh: error (HTTP $(cat "$MOCK/$key.status"))" >&2
  exit 1
fi
cat "$MOCK/$key.out"
MOCK
chmod +x "$WORK/bin/gh"

PASS=0
FAILED=0
N=0

record() {
  if [ "$1" = ok ]; then
    PASS=$((PASS + 1))
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: $2"
    printf '%s\n' "$3" | sed 's/^/    /'
  fi
}

# text EXPECTED_STATUS TEXT: runs the matcher on TEXT alone.
text() {
  local out status=0
  out=$(printf '%s' "$2" | TEXT_ONLY=1 bash "$SCRIPT" 2>&1) || status=$?
  if [ "$status" = "$1" ]; then record ok; else record ko "[$1] text: $2" "$out"; fi
}

# pr EXPECTED_STATUS EXPECTED_OUTPUT TITLE BODY COMMIT...: runs against a fake
# PR whose body may be "null".
pr() {
  local expected="$1" grep_for="$2" title="$3" body="$4" out status=0 c
  shift 4
  N=$((N + 1))
  MOCK="$WORK/case$N"
  mkdir -p "$MOCK"
  jq -n --arg t "$title" --argjson b "$body" --argjson n $# \
    '{title: $t, body: $b, commits: $n}' >"$MOCK/pulls.out"
  : >"$MOCK/commits.out"
  for c in "$@"; do jq -n --arg m "$c" '$m' -c >>"$MOCK/commits.out"; done
  run_pr "$expected" "$grep_for" "pr: $title"
}

run_pr() {
  local out status=0
  out=$(MOCK="$MOCK" PATH="$WORK/bin:$PATH" REPO=o/r PR=1 bash "$SCRIPT" 2>&1) || status=$?
  if [ "$status" = "$1" ] && printf '%s' "$out" | grep -qF -- "$2"; then
    record ok
  else
    record ko "[$1, $2] $3" "$out"
  fi
}

# Every keyword, in several cases, fails in a partial PR.
for kw in close closes closed fix fixes fixed resolve resolves resolved; do
  upper=$(printf '%s' "$kw" | tr '[:lower:]' '[:upper:]')
  cap="$(printf '%s' "${kw:0:1}" | tr '[:lower:]' '[:upper:]')${kw:1}"
  for v in "$kw" "$upper" "$cap"; do
    text 1 "Part of #26. Then $v #26."
    text 1 "Refs #26
$v o/r#26"
    text 1 "part of #26, $v https://github.com/o/r/issues/7"
  done
  text 0 "$kw #26"
done

# Reference forms and variants.
text 1 "Part of #1 closes #2"
text 1 "Refs #1 (fixes #1)"
text 1 "Refs #1 fixes: #1"
text 1 "Refs #1 fixes:#1"
text 1 "Refs #1
- closes   #3"
text 1 "Refs #1 Closes kevin-sakemaer/k#9"
text 1 "Refs #1 Closes some.org/my-repo_2#9"
text 1 "Refs #1 resolves http://github.com/a/b/issues/3"
text 1 "Refs: #1 fix #2"
text 1 "PART OF #1 FIX #2"
text 1 "Part   of #1, close #2"
text 1 "Part of o/r#1, close #2"
text 1 "Part of https://github.com/o/r/issues/1, close #2"
text 1 "REFS #1 Resolved #1"
text 1 "Refs #1 then close #9"
# GH-N, markdown links, scheme-less and www URLs.
text 1 "Part of #1, Fixes GH-1"
text 1 "Part of #1, fixes gh-1"
text 1 "Part of #1, Fixes [#1](https://github.com/o/r/issues/1)"
text 1 "Part of #1, Fixes [o/r#1](https://github.com/o/r/issues/1)"
text 1 "Part of #1, Fixes https://www.github.com/o/r/issues/1"
text 1 "Part of #1, Fixes github.com/o/r/issues/1"
text 1 "Part of #1, Fixes www.github.com/o/r/issues/1"
text 1 "Part of #1, Fixes http://github.com/o/r/issues/1"
text 1 "Part of #1, Fixes <https://github.com/o/r/pull/1>"
text 1 "Part of #1, Fixes: #1"
text 1 "Part of #1, Fixes #1, #2"
text 1 "Part of #1, **Fixes** #1"
# Code is scanned too: fenced blocks and inline code.
text 1 $'Part of #1\n```\nfixes #1\n```'
text 1 $'```\nPart of #1\n```\nfixes #1'
text 1 'Part of #1, Fixes `#1`'
text 1 'Part of #1, `Fixes #1`'
text 1 'Part of `#1`, Fixes #1'
text 1 'Part of [#1](https://github.com/o/r/issues/1), Fixes #1'
text 1 'Refs GH-1, Fixes #1'
text 0 'Fixes `#1`'
text 0 "Part of #1, prefixes the fixture"
# A parenthesized reference is not a closing reference (squash, scope).
text 0 $'docs: typo fix (#12)\nPart of #26'
text 0 $'chore: apply review fixes (#40)\nPart of #26'
text 0 $'feat: resolve (#7)\nPart of #26'
text 0 $'Revert "docs: typo fix (#12)"\nPart of #26'
text 0 $'fix(#12): typo\nPart of #26'
text 0 $'ci: lint fix (#40)\nPart of #26'
text 0 $'Fix (o/r#12)\nPart of #26'
text 1 $'docs: typo fix (#12)\nPart of #26, Fixes #26'
text 1 'Part of #1, Fixes [here](https://github.com/o/r/issues/1)'

# Negatives.
text 0 ""
text 0 "Part of #26. Nothing else."
text 0 "Refs #26: closing keywords are forbidden here."
text 0 "Refs #26 close the file, fix the bug, resolve it."
text 0 "Refs #26 enclose #3 prefix #3 unresolved #3 closest #3"
text 0 "Refs #26 fixture #3 closer #3 fixing #3 resolving #3"
text 0 "Refs #26 close issue 3"
text 0 "Closes #26 and fixes #3"
text 0 "Departs of #1 closes #2"
text 0 "Prefs #1 closes #2"
text 0 "Part of the work, closes #2"
text 0 "Refs commit abc, fixes #2"
text 0 "Closes o/r#1"

# Whole PR: title, body and commits are all scanned.
pr 0 "Not a partial PR" "Add a thing" '"Closes #3"' "Add a thing" "Fix #3"
pr 0 "No closing keyword found." "Add a thing" '"Part of #3"' "Add a thing"
pr 0 "No closing keyword found." "Add a thing" null "Add a thing

Part of #3"
pr 1 "A partial PR must not" "Fix #3" '"Part of #3"' "Add a thing"
pr 1 "Closing keywords found" "Fix #3" '"Part of #3"' "Add a thing"
pr 1 "Closing keywords found" "Add a thing" '"Part of #3\n\nthen close #3"' "x"
pr 1 "Closing keywords found" "Add a thing" '"Part of #3"' "x" "Second

Resolves o/r#3"
pr 1 "Closing keywords found" "Part of #3" null "fixes #4"
pr 1 "Closing keywords found" "Add" null "Refs #3" "Fixed #3"
pr 1 "Closing keywords found" "Add" '"Refs #3"' "a" "b" "c" "closed https://github.com/o/r/issues/3"
pr 0 "No closing keyword found." "Add" '"Refs #3"' "a" "b" "c"

# Fail closed on API errors and inconsistent listings.
N=$((N + 1)); MOCK="$WORK/case$N"; mkdir -p "$MOCK"; echo 500 >"$MOCK/pulls.status"
run_pr 1 "GitHub API call failed" "pull API error"
N=$((N + 1)); MOCK="$WORK/case$N"; mkdir -p "$MOCK"
echo '{"title":"t","body":null,"commits":2}' >"$MOCK/pulls.out"; echo 502 >"$MOCK/commits.status"
run_pr 1 "GitHub API call failed" "commits API error"
N=$((N + 1)); MOCK="$WORK/case$N"; mkdir -p "$MOCK"
echo '{"title":"t","body":null,"commits":2}' >"$MOCK/pulls.out"; echo '"one"' >"$MOCK/commits.out"
run_pr 1 "the listing is incomplete" "truncated commits"
N=$((N + 1)); MOCK="$WORK/case$N"; mkdir -p "$MOCK"
echo '{"title":"t","body":null,"commits":250}' >"$MOCK/pulls.out"; : >"$MOCK/commits.out"
run_pr 1 "cannot list them all" "too many commits"
N=$((N + 1)); MOCK="$WORK/case$N"; mkdir -p "$MOCK"
echo '{"title":"t","body":null}' >"$MOCK/pulls.out"; : >"$MOCK/commits.out"
run_pr 1 "Could not read the number of commits." "missing commit count"
N=$((N + 1)); MOCK="$WORK/case$N"; mkdir -p "$MOCK"
echo 'not json' >"$MOCK/pulls.out"; : >"$MOCK/commits.out"
run_pr 1 "Could not parse the PR." "invalid JSON"

echo "closing_keywords: $PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
