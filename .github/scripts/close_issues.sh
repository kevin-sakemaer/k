#!/usr/bin/env bash
# Closes the issues linked as closing issues of PRs merged into main (#40).
# Merges done by auto-merge with GITHUB_TOKEN neither apply closing keywords nor
# start workflows (pull_request_target `closed` included), so a scheduled sweep
# does it instead.
#
# The issue set comes from GitHub itself: the GraphQL field
# pullRequest.closingIssuesReferences, the linked issues shown in the PR
# sidebar. `Part of #N` and `Refs #N` are never closing references. Only open
# issues of REPO are closed; other repositories and issues that are not open
# are skipped. No body parsing happens here.
#
# Idempotent, and a human reopen wins: the sweep closes an issue first, then
# posts one comment carrying a hidden marker for the PR. An open issue that
# already has a marker (from any PR) posted by github-actions[bot] was reopened by someone after the sweep closed it, so
# it is never closed again. A failed close leaves no marker, so the next run
# retries; a comment that fails after the close fails the job, and the next run
# skips the issue because it is closed.
#
# Required environment: REPO (owner/name), LOOKBACK_HOURS (k.yaml
# close_issues.lookback_hours). Optional: PR, a single PR number to process
# instead of the sweep (workflow_dispatch); it must exist and be merged into
# main. GH can point to another gh binary; tests put a fake gh first in PATH.
# Fails on any API or GraphQL error, and when a result is truncated.
set -euo pipefail

GH="${GH:-gh}"
[ $# -eq 0 ] || { echo "close_issues.sh: unknown argument: $1" >&2; exit 2; }
: "${REPO:?REPO is required}" "${LOOKBACK_HOURS:?LOOKBACK_HOURS is required}"
# Same bound as the k_config schema; the length guard comes first so that a
# huge value never reaches bash arithmetic.
[[ "$LOOKBACK_HOURS" =~ ^[1-9][0-9]{0,2}$ ]] && ((LOOKBACK_HOURS <= 720)) || { echo "::error::invalid LOOKBACK_HOURS: $LOOKBACK_HOURS" >&2; exit 2; }
PR="${PR:-}"
[ -z "$PR" ] || [[ "$PR" =~ ^[1-9][0-9]*$ ]] || { echo "::error::invalid PR: $PR" >&2; exit 2; }

fields='number baseRefName merged mergeCommit { oid }
  closingIssuesReferences(first: 100) {
    totalCount
    nodes { number state repository { nameWithOwner } }
  }'

# Prints one "<pr> <merge sha> <issue> <state> <owner/name>" line per closing
# reference of one PR object (JSON on stdin); fails when truncated.
# shellcheck disable=SC2016 # jq program, not shell expansions.
refs_of='def refs:
  if .baseRefName != "main" or .merged != true then error("PR #\(.number) is not merged into main")
  elif .closingIssuesReferences.totalCount > (.closingIssuesReferences.nodes | length)
  then error("closingIssuesReferences of #\(.number) truncated")
  else . as $pr | .closingIssuesReferences.nodes[]
    | "\($pr.number) \($pr.mergeCommit.oid) \(.number) \(.state) \(.repository.nameWithOwner)" end;
if (.errors // []) | length > 0 then error("GraphQL errors: \(.errors | map(.message) | join("; "))") else . end'

if [ -n "$PR" ]; then
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
  query='query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) { '"$fields"' } }
  }'
  args=(-F owner="${REPO%%/*}" -F name="${REPO#*/}" -F number="$PR")
  select='.data.repository.pullRequest // error("PR #'"$PR"' not found") | refs'
else
  since="$(date -u -d "-$LOOKBACK_HOURS hours" +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
  query='query($q: String!) {
    search(type: ISSUE, first: 100, query: $q) {
      issueCount
      nodes { ... on PullRequest { '"$fields"' } }
    }
  }'
  args=(-f q="repo:$REPO is:pr is:merged base:main merged:>=$since")
  select='.data.search
    | if .issueCount > (.nodes | length) then error("search truncated: \(.issueCount) merged PRs") else . end
    | .nodes[] | refs'
  echo "Sweeping PRs merged into main since $since."
fi

json="$("$GH" api graphql -f query="$query" "${args[@]}")" \
  || { echo "::error::GraphQL query failed" >&2; exit 1; }
if ! refs="$(jq -r "$refs_of | $select" <<<"$json")"; then
  echo "::error::invalid GraphQL answer" >&2
  exit 1
fi
[ -n "$refs" ] || { echo "No closing issue to process."; exit 0; }

repo_lc="${REPO,,}"
declare -A done_issues=()
while read -r pr sha n state owner; do
  if [ "${owner,,}" != "$repo_lc" ]; then
    echo "$owner#$n (from #$pr) is in another repository: skipped."
  elif [ "$state" != OPEN ] || [ -n "${done_issues[${owner,,}#$n]:-}" ]; then
    echo "#$n (from #$pr) is already closed: nothing to do."
  else
    marker="<!-- close-issues: #$pr -->"
    # Only markers posted by this workflow count: anyone can comment, so a
    # marker from any other author must not stop the close. --paginate reads
    # every page, so a marker after the first page is not missed.
    bodies="$("$GH" api --paginate "repos/$REPO/issues/$n/comments" \
      --jq '.[] | select(.user.login == "github-actions[bot]" and .user.type == "Bot") | .body')" \
      || { echo "::error::could not read the comments of #$n" >&2; exit 1; }
    if grep -qF -- "<!-- close-issues: #" <<<"$bodies"; then
      # The sweep already closed it (for this PR or another one): someone
      # reopened it on purpose, and a human reopen wins.
      echo "#$n (from #$pr) was reopened after the sweep closed it: skipped."
      done_issues[${owner,,}#$n]=1
      continue
    fi
    "$GH" api -X PATCH "repos/$REPO/issues/$n" -f state=closed -f state_reason=completed >/dev/null \
      || { echo "::error::could not close #$n" >&2; exit 1; }
    "$GH" api -X POST "repos/$REPO/issues/$n/comments" \
      -f body="Closed by #$pr (merge commit $sha). $marker" >/dev/null \
      || { echo "::error::closed #$n but could not comment on it" >&2; exit 1; }
    echo "Closed #$n (from #$pr)."
  fi
  done_issues[${owner,,}#$n]=1
done <<<"$refs"
