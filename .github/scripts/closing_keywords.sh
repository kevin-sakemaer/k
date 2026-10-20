#!/usr/bin/env bash
# Closing keywords guard (#26): a partial PR, one whose title, description or
# commit messages reference an issue with "Part of #N" or "Refs #N", must not
# contain any GitHub closing keyword (close, closes, closed, fix, fixes, fixed,
# resolve, resolves, resolved) followed by an issue reference anywhere in its
# title, description or commit messages. Matching is case-insensitive and
# covers #N, GH-N, owner/repo#N and issue or pull URLs with or without
# scheme or www. A PR that is not partial may use a closing keyword when it
# fully delivers the issue. Fails closed on any API error.
#
# One rule, stricter than GitHub, applied to both the partial marker and the
# closing keywords: everything is scanned, including fenced code blocks and
# inline code. Before matching, the markdown characters ` [ ] ( ) < > * ~ are
# replaced by spaces, so code spans, links, autolinks and emphasis cannot hide
# a reference. Only the first reference after a keyword is needed to fail.
#
# Required environment: REPO (owner/name), PR (number).
# GH can point to another gh binary; tests put a fake gh first in PATH.
# With TEXT_ONLY=1 the script reads the text to check from stdin instead.
set -euo pipefail

GH="${GH:-gh}"
# GitHub lists at most 250 commits per pull request.
MAX_COMMITS=250

NAME='[[:alnum:]_.-]+'
URL="(https?://)?(www\\.)?github\\.com/$NAME/$NAME/(issues|pull)/[0-9]+"
REF="(#[0-9]+|gh-[0-9]+|$NAME/$NAME#[0-9]+|$URL)"
B='(^|[^[:alnum:]_])'
CLOSING="$B(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*$REF"
PARTIAL="$B(part[[:space:]]+of|refs)[[:space:]]*:?[[:space:]]*$REF"

fail() {
  echo "::error::$*"
  exit 1
}

api() {
  local out
  if ! out=$("$GH" api "$@"); then
    echo "::error::GitHub API call failed: gh api $*" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

# check_text TEXT: fails when TEXT is partial and has a closing keyword.
check_text() {
  local partial closing text
  # Markdown syntax must not hide a reference (see the header).
  text=$(printf '%s\n' "$1" | tr '`[]()<>*~' '         ')
  set -- "$text"
  partial=$(printf '%s\n' "$1" | grep -Eio "$PARTIAL" | sed -E 's/^[^[:alnum:]]+//' || true)
  if [ -z "$partial" ]; then
    echo "Not a partial PR (no 'Part of #N' or 'Refs #N'); closing keywords are allowed."
    return 0
  fi
  echo "Partial PR, references:"
  printf '%s\n' "$partial" | sed 's/^/  /'
  closing=$(printf '%s\n' "$1" | grep -Eio "$CLOSING" | sed -E 's/^[^[:alnum:]]+//' || true)
  if [ -n "$closing" ]; then
    echo "Closing keywords found:"
    printf '%s\n' "$closing" | sed 's/^/  /'
    fail "A partial PR must not contain closing keywords in its title, description or commit messages; remove them or drop 'Part of'/'Refs' if the PR fully delivers the issue."
  fi
  echo "No closing keyword found."
}

main() {
  if [ "${TEXT_ONLY:-0}" = 1 ]; then
    check_text "$(cat)"
    return
  fi
  : "${REPO:?REPO is required}" "${PR:?PR is required}"
  local pull count text messages listed
  pull=$(api "repos/$REPO/pulls/$PR")
  count=$(printf '%s' "$pull" | jq -r '.commits') || fail "Could not parse the PR."
  [[ "$count" =~ ^[0-9]+$ ]] || fail "Could not read the number of commits."
  [ "$count" -lt "$MAX_COMMITS" ] || fail "PR has $count commits; GitHub cannot list them all, so commit messages cannot be verified."
  text=$(printf '%s' "$pull" | jq -r '.title, (.body // "")') || fail "Could not parse the PR."
  # One JSON string per commit message, so multi-line messages count once.
  messages=$(api --paginate "repos/$REPO/pulls/$PR/commits?per_page=100" --jq '.[] | .commit.message | @json')
  listed=$(printf '%s\n' "$messages" | grep -c . || true)
  [ "$listed" = "$count" ] || fail "Listed $listed commits but the PR reports $count; the listing is incomplete."
  messages=$(printf '%s\n' "$messages" | jq -r '.') || fail "Could not parse the commit messages."
  check_text "$text"$'\n'"$messages"
}

main "$@"
