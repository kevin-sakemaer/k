#!/usr/bin/env bash
# Freshness helpers shared by review_gate.sh and github_guard.sh (#8, #15).
# Sourced, not executed. The caller defines fail() and api(), sets REPO and,
# before head_push_time, HEAD_SHA, HEAD_REPO and HEAD_REF (and BASE_REF for
# same_patch).
#
# Rule: a label approves the current head only if its latest "labeled" timeline
# event is strictly newer than the server-side time the head SHA was pushed.
# Commit dates are never used because they can be forged.

# Timestamps must be strict YYYY-MM-DDTHH:MM:SSZ and are compared as epochs,
# never as strings: a fractional second or an offset fails closed.


# True when $1 is strictly newer than $2. Empty or malformed values, and ties,
# are not newer.
is_newer() {
  local a b
  a=$(to_epoch "$1") && b=$(to_epoch "$2") && [ "$a" -gt "$b" ]
}

# extreme gt|lt: prints the greatest (gt) or smallest (lt) non-empty line of
# stdin, or nothing. Fails on any malformed timestamp.
extreme() {
  local best="" best_e="" line e
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! e=$(to_epoch "$line"); then
      echo "::error::Malformed timestamp '$line'." >&2
      return 1
    fi
    if [ -z "$best_e" ] || [ "$e" -"$1" "$best_e" ]; then
      best="$line" best_e="$e"
    fi
  done
  printf '%s' "$best"
}

latest() { extreme gt; }
earliest() { extreme lt; }

# Fields of one API record are joined with the unit separator (0x1f), a
# non-whitespace IFS, so empty fields are kept instead of collapsing as with a
# tab. US_JQ is the jq suffix that builds such a record from an array.
US=$'\x1f'
US_JQ='map(if . == null then "" else tostring end) | join("\u001f")'

# read_record LINE NAME...: splits LINE on US into exactly the NAMEs. Fails
# when the field count differs (fields shifted or missing).
read_record() {
  local line="$1" i=0 name
  shift
  local -a fields
  IFS="$US" read -r -a fields <<<"$line$US."
  [ "${#fields[@]}" -eq $(($# + 1)) ] && [ "${fields[$#]}" = . ] || return 1
  for name in "$@"; do
    printf -v "$name" '%s' "${fields[i]}"
    i=$((i + 1))
  done
}

# True when a "gh api -i" response (headers and body) shows a rate limit.
is_rate_limited() {
  local line lower
  while IFS= read -r line; do
    line="${line%$'\r'}"
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      retry-after:*) return 0 ;;
      x-ratelimit-remaining:*)
        if [ "$(printf '%s' "${lower#*:}" | tr -d ' ')" = 0 ]; then return 0; fi
        ;;
      *"rate limit"*) return 0 ;;
    esac
  done <<<"$1"
  return 1
}

# Server-side time of the push that brought HEAD_SHA, from the activity API.
# Prints the timestamp (possibly empty) and returns 0, or returns 2 when the API
# answers an explicit access 404 or 403 (fallback allowed). Any other error is
# fatal, including a 403 caused by a primary or secondary rate limit: GitHub
# also answers 403 for those, and they must not enable the weaker fallback.
activity_push_time() {
  local probe status
  if probe=$("$GH" api -i "repos/$HEAD_REPO/activity?ref=refs/heads/$HEAD_REF&per_page=1" 2>/dev/null); then
    status=200
  else
    status=$(printf '%s\n' "$probe" | sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')
  fi
  if [ "$status" = 403 ] && is_rate_limited "$probe"; then
    echo "::error::Activity API rate limited (HTTP 403); not falling back. Re-run the job later." >&2
    return 1
  fi
  case "$status" in
    200) ;;
    403 | 404) return 2 ;;
    *)
      # Runs in a command substitution: report on stderr, then return an error.
      echo "::error::Activity API failed (HTTP ${status:-unknown})." >&2
      return 1
      ;;
  esac
  local entries sha ts
  entries=$(api --paginate "repos/$HEAD_REPO/activity?ref=refs/heads/$HEAD_REF&per_page=100" \
    --jq '.[] | "\(.after) \(.timestamp)"')
  while read -r sha ts; do
    if [ "$sha" = "$HEAD_SHA" ]; then
      printf '%s\n' "$ts"
    fi
  done <<<"$entries" | latest
}

# Prints the time of the latest "labeled NAME" event of a timeline listing
# ("event label created_at" lines), or nothing.
label_added_at() {
  local want="$1" event name ts
  while read -r event name ts; do
    if [ "$event" = "labeled" ] && [ "$name" = "$want" ]; then printf '%s\n' "$ts"; fi
  done <<<"$2" | latest
}

# Sets HEAD_AT (possibly empty) and HEAD_AT_SOURCE from the activity API, or
# from the fallback when it answers an access 403 or 404. Takes the timeline
# listing. Exits on any other error. Must not run in a command substitution.
head_push_time() {
  local timeline="$1" rc=0 event name ts
  HEAD_AT=$(activity_push_time) || rc=$?
  if [ "$rc" -eq 0 ]; then
    HEAD_AT_SOURCE="activity API"
  elif [ "$rc" -eq 2 ]; then
    # Fallback: latest of the head_ref_force_pushed, reopened and
    # head_ref_restored timeline events and the first workflow run for the
    # head SHA. Both calls must succeed.
    local forced_at run_at runs
    forced_at=$(while read -r event name ts; do
      case "$event" in
        head_ref_force_pushed | reopened | head_ref_restored) printf '%s\n' "$ts" ;;
      esac
    done <<<"$timeline" | latest)
    runs=$(api --paginate "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&event=pull_request&per_page=100" \
      --jq '.workflow_runs[].created_at')
    run_at=$(printf '%s\n' "$runs" | earliest)
    HEAD_AT=$(printf '%s\n%s\n' "$forced_at" "$run_at" | latest)
    HEAD_AT_SOURCE="fallback: force-push, reopened and head_ref_restored events / first workflow run"
  else
    exit 1
  fi
}

# Same-patch rule (#52). With strict up-to-date checks every merge on main
# makes approved PRs BEHIND, and the update push used to drop the approval
# labels. A label still approves a new head when the PR patch is unchanged:
# the approved SHA is the head when the label was added (latest activity entry
# strictly before its latest "labeled" event; never the PR head), and the
# patch-ids of git diff merge-base..SHA (merge-base with the base branch tip)
# must match for both SHAs. Both git patch-id --stable and --verbatim must
# match: --stable alone ignores whitespace, which can be meaningful (YAML).
# Git objects are fetched into a throwaway bare repository; nothing from the
# PR is checked out or run. Any error or doubt means "not the same patch".
# Same-repository PRs only: a fork head (HEAD_REPO != REPO) always drops.
# Needs BASE_REF besides the freshness variables. The remote is always
# https://github.com/$REPO.git; GATE_GIT_URL is a test-only override, honored
# only with K_GATE_TEST=1, which no workflow sets.

# Prints the epoch of a strict YYYY-MM-DDTHH:MM:SSZ timestamp, or fails.
to_epoch() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  date -u -d "$1" +%s 2>/dev/null
}

# Prints the approved SHA for a label added at $1, from the activity API.
approved_sha_at() {
  local entries sha ts e at best="" best_e=""
  if ! at=$(to_epoch "$1"); then
    echo "Malformed label time '$1': the approved SHA is unknown." >&2
    return 1
  fi
  if ! entries=$("$GH" api --paginate "repos/$HEAD_REPO/activity?ref=refs/heads/$HEAD_REF&per_page=100" \
    --jq '.[] | "\(.after) \(.timestamp)"' 2>/dev/null); then
    echo "Activity API failed: the approved SHA cannot be identified." >&2
    return 1
  fi
  while read -r sha ts; do
    [ -n "$sha$ts" ] || continue
    if ! e=$(to_epoch "$ts"); then
      echo "Malformed push time '$ts': the approved SHA is unknown." >&2
      return 1
    fi
    if [ "$e" -eq "$at" ]; then
      echo "A push has the same time as the label: ambiguous approved SHA." >&2
      return 1
    fi
    if [ "$e" -lt "$at" ] && { [ -z "$best_e" ] || [ "$e" -gt "$best_e" ]; }; then
      best="$sha" best_e="$e"
    elif [ "$e" -lt "$at" ] && [ "$e" -eq "$best_e" ] && [ "$sha" != "$best" ]; then
      echo "Two pushes at the same time before the label: ambiguous." >&2
      return 1
    fi
  done <<<"$entries"
  if ! [[ "$best" =~ ^[0-9a-f]{40}$ ]] || [[ "$best" =~ ^0+$ ]]; then
    echo "No push before the label: the approved SHA is unknown." >&2
    return 1
  fi
  printf '%s' "$best"
}

# git on bare repository $1 only, whatever GIT_* variables the caller has
# (a git hook sets GIT_DIR and GIT_INDEX_FILE).
# No injected config either: GIT_CONFIG_* variables are dropped, and system
# and global config files are ignored.
bare_git() {
  local dir="$1" v unset=()
  shift
  for v in $(compgen -e); do
    case "$v" in GIT_CONFIG_*) unset+=(-u "$v") ;; esac
  done
  env "${unset[@]}" -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_COMMON_DIR -u GIT_NAMESPACE -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_COUNT GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 git --git-dir="$dir" "$@"
}

# Binary files: patch-id hashes the full blob ids of the index line
# (--full-index), and --binary adds the content itself, so different binary
# content never gives the same id (both are kept as defense in depth).
# Prints "STABLE VERBATIM" patch-ids of merge-base..$2 in bare repository $1.
patch_ids() {
  local mb s v
  mb=$(bare_git "$1" merge-base refs/k/base "$2") || return 1
  bare_git "$1" diff --binary --full-index --no-renames --no-ext-diff \
    --no-textconv --src-prefix=a/ --dst-prefix=b/ "$mb" "$2" >"$1/patch" || return 1
  if ! [ -s "$1/patch" ]; then
    echo "Empty diff for $2: no patch to compare." >&2
    return 1
  fi
  s=$(bare_git "$1" patch-id --stable <"$1/patch" | awk '{print $1}') || return 1
  v=$(bare_git "$1" patch-id --verbatim <"$1/patch" | awk '{print $1}') || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] && [[ "$v" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s %s' "$s" "$v"
}

# same_patch LABEL TIMELINE: returns 0 only when the current head has the same
# patch as the SHA approved by LABEL. Logs the decision and both patch-ids.
# Sets APPROVED_SHA and PATCH_ID. Never exits.
same_patch() {
  local label="$1" at sha dir old="" new="" url
  APPROVED_SHA="" PATCH_ID=""
  if ! at=$(label_added_at "$label" "$2"); then
    echo "Same-patch check for $label: malformed label time: drop."
    return 1
  fi
  if [ -z "$at" ]; then
    echo "Same-patch check for $label: no labeled event, no approval record: drop."
    return 1
  fi
  if [ "${HEAD_REPO:-}" != "$REPO" ]; then
    echo "Same-patch check for $label: head repository ${HEAD_REPO:-unknown} is not $REPO (fork): drop."
    return 1
  fi
  if ! [[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || [ -z "${BASE_REF:-}" ]; then
    echo "Same-patch check for $label: head SHA or base branch unknown: drop."
    return 1
  fi
  if ! sha=$(approved_sha_at "$at"); then
    echo "Same-patch check for $label: approved SHA unknown: drop."
    return 1
  fi
  APPROVED_SHA="$sha"
  url="https://github.com/$REPO.git"
  if [ "${K_GATE_TEST:-}" = 1 ] && [ -n "${GATE_GIT_URL:-}" ]; then
    url="$GATE_GIT_URL"
  fi
  if dir=$(mktemp -d) && bare_git "$dir" init -q --bare &&
    bare_git "$dir" fetch -q --no-tags "$url" "+refs/heads/$BASE_REF:refs/k/base" \
      "$sha" "$HEAD_SHA" >&2; then
    old=$(patch_ids "$dir" "$sha") || old=""
    new=$(patch_ids "$dir" "$HEAD_SHA") || new=""
  else
    echo "Could not fetch $BASE_REF, $sha and $HEAD_SHA." >&2
  fi
  [ -n "${dir:-}" ] && rm -rf "$dir"
  echo "Approved SHA for $label: $sha (label added at $at)"
  echo "Patch-id (stable verbatim) at approved SHA: ${old:-error}"
  echo "Patch-id (stable verbatim) at head $HEAD_SHA: ${new:-error}"
  if [ -n "$old" ] && [ "$old" = "$new" ]; then
    PATCH_ID="${new%% *}"
    echo "Same-patch check for $label: same patch: keep."
    return 0
  fi
  echo "Same-patch check for $label: patch differs or unknown: drop."
  return 1
}

# keep_after_push LABEL: on synchronize, returns 0 when LABEL may stay, after
# writing a bot marker comment that records the head as approved-by-rebase.
# Any error returns 1, and the caller removes the label.
keep_after_push() {
  local timeline body
  if ! timeline=$("$GH" api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" \
    --jq '.[] | "\(.event) \(.label.name // "-") \(.created_at // "")"'); then
    echo "Timeline API failed: drop $1." >&2
    return 1
  fi
  same_patch "$1" "$timeline" || return 1
  body="<!-- k-gate:approved-by-rebase label=$1 sha=$HEAD_SHA from=$APPROVED_SHA patch-id=$PATCH_ID -->
\`$1\` kept: $HEAD_SHA has the same patch as the approved $APPROVED_SHA (patch-id $PATCH_ID)."
  if ! "$GH" api -X POST "repos/$REPO/issues/$PR/comments" -f body="$body" >/dev/null; then
    echo "Could not write the approved-by-rebase marker comment: drop $1." >&2
    return 1
  fi
  echo "Marker comment written: $HEAD_SHA approved-by-rebase for $1."
}
