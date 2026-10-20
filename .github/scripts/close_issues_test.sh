#!/usr/bin/env bash
# Tests for close_issues.sh, in plain bash, with a fake gh placed first in PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/close_issues.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# The fake gh logs its calls (one line each, new lines flattened).
# "api graphql" prints "$MOCK/graphql.json", or fails when "$MOCK/fail_graphql"
# exists. Reading the comments of #<n> applies the --jq filter, like gh, to
# the JSON array in "$MOCK/comments_<n>" (empty by default). "$MOCK/fail_<verb>_<n>" (verb GET, POST or PATCH) fails that call.
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" | tr '\n' ' ' >>"$MOCK/calls" && echo >>"$MOCK/calls"
if [ "$2" = graphql ]; then
  [ ! -f "$MOCK/fail_graphql" ] || { echo "HTTP 502" >&2; exit 1; }
  cat "$MOCK/graphql.json"
  exit 0
fi
verb=GET
[ "$2" != -X ] || verb="$3"
n="$(grep -oE 'issues/[0-9]+' <<<"$*" | head -n1)"
n="${n#issues/}"
[ ! -f "$MOCK/fail_${verb}_$n" ] || exit 1
if [ "$verb" = GET ]; then
  filter=.
  while [ $# -gt 0 ]; do [ "$1" != --jq ] || filter="$2"; shift; done
  if [ -f "$MOCK/comments_$n" ]; then jq -r "$filter" "$MOCK/comments_$n"; else jq -r "$filter" <<<'[]'; fi
fi
MOCK
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

pass=0 failed=0
ok() { pass=$((pass + 1)); }
ko() { failed=$((failed + 1)); echo "FAIL: $*" >&2; }

# issue <n> <state> <owner/name>: one closingIssuesReferences node.
issue() { printf '{"number":%s,"state":"%s","repository":{"nameWithOwner":"%s"}}' "$1" "$2" "$3"; }
# pr <number> <issue nodes, comma separated> [totalCount] [base] [merged]
pr() {
  local nodes="$2" total="${3:-}"
  [ -n "$total" ] || total="$( (grep -o '"number"' <<<"$nodes" || true) | wc -l)"
  printf '{"number":%s,"baseRefName":"%s","merged":%s,"mergeCommit":{"oid":"sha%s"},' \
    "$1" "${4:-main}" "${5:-true}" "$1"
  printf '"closingIssuesReferences":{"totalCount":%s,"nodes":[%s]}}' "$total" "$nodes"
}
# sweep <PR objects, comma separated> [issueCount]: a fresh mock with a search answer.
fresh() {
  export MOCK="$WORK/mock$((pass + failed))"
  rm -rf "$MOCK" && mkdir -p "$MOCK" && : >"$MOCK/calls"
}
sweep() {
  fresh
  local count="${2:-}"
  [ -n "$count" ] || count="$( (grep -o '"baseRefName"' <<<"$1" || true) | wc -l)"
  printf '{"data":{"search":{"issueCount":%s,"nodes":[%s]}}}\n' "$count" "$1" >"$MOCK/graphql.json"
}
single() {
  fresh
  printf '{"data":{"repository":{"pullRequest":%s}}}\n' "$1" >"$MOCK/graphql.json"
}
# comment <login> <type> <body>: one issue comment as the REST API returns it.
comment() { jq -nc --arg l "$1" --arg t "$2" --arg b "$3" '{user: {login: $l, type: $t}, body: $b}'; }
bot="github-actions[bot]"
run() { REPO=Owner/Repo LOOKBACK_HOURS=72 bash "$SCRIPT" >"$MOCK/log" 2>&1; }
writes() { grep -c -- "-X" "$MOCK/calls" || true; }

sweep "$(pr 99 "$(issue 4 OPEN owner/repo)")"
if run \
  && grep -q "q=repo:Owner/Repo is:pr is:merged base:main merged:>=20[0-9-]*T[0-9:]*Z" "$MOCK/calls" \
  && grep -q "POST repos/Owner/Repo/issues/4/comments -f body=Closed by #99 (merge commit sha99). <!-- close-issues: #99 -->" "$MOCK/calls" \
  && grep -q "PATCH repos/Owner/Repo/issues/4 -f state=closed -f state_reason=completed" "$MOCK/calls"; then
  ok
else ko "same-repository open issue: comment and close"; fi

sweep "$(pr 99 "$(issue 8 OPEN other/repo)")"
if run && [ "$(writes)" = 0 ] && grep -q "other/repo#8 (from #99) is in another repository" "$MOCK/log"; then
  ok
else ko "other-repository issue: skipped"; fi

sweep "$(pr 99 "$(issue 5 CLOSED owner/repo)")"
if run && [ "$(writes)" = 0 ] && grep -q "#5 (from #99) is already closed" "$MOCK/log"; then
  ok
else ko "already closed issue: skipped"; fi

sweep "$(pr 98 "$(issue 1 OPEN owner/repo),$(issue 1 OPEN x/y)"),$(pr 99 "$(issue 1 OPEN owner/repo),$(issue 3 CLOSED owner/repo)")"
if run && [ "$(writes)" = 2 ] && grep -q "issues/1 -f state=closed" "$MOCK/calls"; then
  ok
else ko "several PRs: each open same-repository issue is closed once"; fi

sweep ""
if run && [ "$(writes)" = 0 ] && grep -q "No closing issue" "$MOCK/log"; then
  ok
else ko "no merged PR: no-op"; fi

sweep "$(pr 99 "")"
if run && [ "$(writes)" = 0 ] && grep -q "No closing issue" "$MOCK/log"; then
  ok
else ko "empty closing list: no-op"; fi

sweep "$(pr 99 "$(issue 4 OPEN owner/repo)")" && : >"$MOCK/fail_graphql"
if run; then ko "GraphQL transport error must fail"; elif [ "$(writes)" = 0 ]; then ok; else ko "GraphQL error: no write"; fi

sweep "" && echo '{"data":null,"errors":[{"message":"Something went wrong"}]}' >"$MOCK/graphql.json"
if run; then ko "GraphQL errors field must fail"; elif grep -q "Something went wrong" "$MOCK/log"; then ok; else ko "GraphQL error message"; fi

sweep "$(pr 99 "$(issue 4 OPEN owner/repo)")" 101
if run; then ko "truncated search must fail"; elif [ "$(writes)" = 0 ]; then ok; else ko "truncated search: no write"; fi

sweep "$(pr 99 "$(issue 4 OPEN owner/repo)" 101)"
if run; then ko "truncated closing list must fail"; elif [ "$(writes)" = 0 ]; then ok; else ko "truncated list: no write"; fi

# A failed close leaves no marker: the re-run closes once and comments once.
sweep "$(pr 99 "$(issue 7 OPEN owner/repo)")" && : >"$MOCK/fail_PATCH_7"
if run; then ko "failed close must fail"; elif ! grep -q POST "$MOCK/calls"; then ok; else ko "failed close: no comment"; fi
rm "$MOCK/fail_PATCH_7" && : >"$MOCK/calls"
if run && [ "$(grep -c PATCH "$MOCK/calls" || true)" = 1 ] && [ "$(grep -c POST "$MOCK/calls" || true)" = 1 ] \
  && [ "$(grep -n PATCH "$MOCK/calls" | cut -d: -f1)" -lt "$(grep -n POST "$MOCK/calls" | cut -d: -f1)" ]; then
  ok
else ko "re-run after a failed close: closed once, then one comment"; fi

# Reopened by hand after the sweep closed it (marker present, from any PR): left open.
for from in 99 12; do
  sweep "$(pr 99 "$(issue 7 OPEN owner/repo)")"
  printf '[%s,%s]' "$(comment "$bot" Bot "Closed by #$from (merge commit sha$from). <!-- close-issues: #$from -->")" \
    "$(comment someone User "Reopened: regression.")" >"$MOCK/comments_7"
  if run && [ "$(writes)" = 0 ] && grep -q "#7 (from #99) was reopened after the sweep closed it: skipped." "$MOCK/log"; then
    ok
  else ko "issue reopened by hand (marker from #$from): never closed again"; fi
done

# A marker posted by anyone else (a user, a user named like the bot, another
# app bot) is ignored: each half of the author check is needed.
for author in "someone User" "$bot User" "other-app[bot] Bot"; do
  sweep "$(pr 99 "$(issue 7 OPEN owner/repo)")"
  printf '[%s]' "$(comment "${author% *}" "${author##* }" "<!-- close-issues: #99 -->")" >"$MOCK/comments_7"
  if run && grep -q "PATCH repos/Owner/Repo/issues/7" "$MOCK/calls" && grep -q "POST repos/Owner/Repo/issues/7/comments" "$MOCK/calls"; then
    ok
  else ko "spoofed marker ($author) must not stop the close"; fi
done

# Comments are read with --paginate, so a marker after the first page counts.
sweep "$(pr 99 "$(issue 7 OPEN owner/repo)")"
if run && grep -q "api --paginate repos/Owner/Repo/issues/7/comments" "$MOCK/calls"; then ok; else ko "comments are paginated"; fi

# The comment fails after the close: the job fails; the next run sees a closed issue.
sweep "$(pr 99 "$(issue 7 OPEN owner/repo)")" && : >"$MOCK/fail_POST_7"
if run; then ko "comment error after close must fail"
elif grep -q "PATCH repos/Owner/Repo/issues/7" "$MOCK/calls" && grep -q "closed #7 but could not comment" "$MOCK/log"; then ok
else ko "comment error after close: closed, then error"; fi
sweep "$(pr 99 "$(issue 7 CLOSED owner/repo)")"
if run && [ "$(writes)" = 0 ]; then ok; else ko "next run after a comment error: no-op"; fi

sweep "$(pr 99 "$(issue 7 OPEN owner/repo)")" && : >"$MOCK/fail_GET_7"
if run; then ko "comment read error must fail"; elif [ "$(writes)" = 0 ]; then ok; else ko "comment read error: no write"; fi

single "$(pr 41 "$(issue 4 OPEN owner/repo)")"
if REPO=Owner/Repo LOOKBACK_HOURS=72 PR=41 bash "$SCRIPT" >"$MOCK/log" 2>&1 \
  && grep -q "\-F number=41" "$MOCK/calls" && grep -q "PATCH repos/Owner/Repo/issues/4" "$MOCK/calls"; then
  ok
else ko "single PR: closes its issues"; fi

single null
if REPO=Owner/Repo LOOKBACK_HOURS=72 PR=404 bash "$SCRIPT" >"$MOCK/log" 2>&1; then
  ko "missing PR must fail"
elif grep -q "PR #404 not found" "$MOCK/log" && [ "$(writes)" = 0 ]; then ok; else ko "missing PR: message, no write"; fi

single "$(pr 41 "$(issue 4 OPEN owner/repo)" "" main false)"
if REPO=Owner/Repo LOOKBACK_HOURS=72 PR=41 bash "$SCRIPT" >"$MOCK/log" 2>&1; then
  ko "unmerged PR must fail"
elif [ "$(writes)" = 0 ]; then ok; else ko "unmerged PR: no write"; fi

single "$(pr 41 "$(issue 4 OPEN owner/repo)" "" dev)"
if REPO=Owner/Repo LOOKBACK_HOURS=72 PR=41 bash "$SCRIPT" >"$MOCK/log" 2>&1; then
  ko "PR merged into another base must fail"
else ok; fi

for env in "LOOKBACK_HOURS=72" "REPO=o/r" "REPO=o/r LOOKBACK_HOURS=0" "REPO=o/r LOOKBACK_HOURS=721" "REPO=o/r LOOKBACK_HOURS=99999999999999999999" "REPO=o/r LOOKBACK_HOURS=72 PR=x"; do
  fresh
  if env -u REPO -u LOOKBACK_HOURS -u PR $env bash "$SCRIPT" >/dev/null 2>&1; then
    ko "invalid environment must fail: $env"
  elif [ ! -s "$MOCK/calls" ]; then ok; else ko "invalid environment: no call: $env"; fi
done

if bash "$SCRIPT" --bogus >/dev/null 2>&1; then ko "unknown argument must fail"; else ok; fi

echo "close_issues_test: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
