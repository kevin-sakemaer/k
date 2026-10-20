#!/usr/bin/env bash
# Single source of the local and CI checks (issue #16).
# Used by the `test` CI job and by the git hooks in tool/hooks.
#
# Usage: tool/check.sh [--fast]
#   --fast  skip tests and coverage (used by the pre-commit hook; the
#           pre-push hook and CI always run the full check).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fast=false
for arg in "$@"; do
  case "$arg" in
    --fast) fast=true ;;
    *) echo "check.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
skip() {
  printf 'SKIP: %s\n' "$*"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::SKIP: $*"; fi
}
warn() {
  printf 'WARNING: %s\n' "$*" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; fi
}
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; fi
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
run() { "$@" || fail "command failed: $*"; }

# skip_missing <file> <issue>: skip a repository script that is not on main
# yet. The skip is only allowed while its issue is open.
skip_missing() {
  local file="$1" issue="$2" state=""
  if command -v gh >/dev/null 2>&1; then
    state="$(gh issue view "$issue" --json state --jq .state 2>/dev/null)" || state=""
  fi
  case "$state" in
    OPEN) skip "$file not found (issue #$issue is still open)." ;;
    "")
      # In CI an unverifiable skip must not pass silently; locally it warns.
      if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        fail "$file not found and the state of issue #$issue could not be checked (gh missing or failing): cannot verify the skip in CI"
      fi
      warn "$file not found and the state of issue #$issue could not be checked (gh missing or failing)."
      ;;
    *) fail "$file not found but issue #$issue is $state: the script was expected by now" ;;
  esac
}

# k.yaml is mandatory: there is no default value outside of it.
[ -f k.yaml ] || fail "k.yaml is required"

step "bash tests"
for t in .github/scripts/review_gate_test.sh .github/scripts/auto_merge_test.sh .github/scripts/github_guard_test.sh tool/check_test.sh; do
  [ -f "$t" ] || fail "bash test not found: $t"
  bash "$t" || fail "bash tests failed: $t"
done

if [ ! -f pubspec.yaml ]; then
  fail "pubspec.yaml is missing at the repository root"
fi

# --enforce-lockfile: a pubspec.lock that is missing or out of sync with the
# pubspecs fails instead of being rewritten (#6).
step "dart pub get --enforce-lockfile"
run dart pub get --enforce-lockfile

step "dart format"
dart format --output=none --set-exit-if-changed . \
  || fail "code is not formatted; run 'dart format .'"

step "dart analyze --fatal-infos"
dart analyze --fatal-infos || fail "dart analyze reported diagnostics"

# Repository scripts introduced by other issues. A check whose script is not
# on main yet is skipped while its issue is open, and fails the job once the
# issue is closed. A script that is already on main must exist.

# run_script <file> <args>...: runs a repository script. A workspace package
# executable (packages/<name>/bin/<name>.dart) is run by package name, because
# `dart run <path>` cannot resolve the package's own imports from the
# workspace root; any other file is run by path.
run_script() {
  local file="$1" name
  shift
  name="$(basename "$file" .dart)"
  if [ "$file" = "packages/$name/bin/$name.dart" ]; then
    dart run "$name" "$@"
  else
    dart run "$file" "$@"
  fi
}

# check_script <label> <issue|required> <file> [args]...: runs <file>. When it
# is missing, "required" fails the job; an issue number applies skip_missing.
check_script() {
  local label="$1" issue="$2" file="$3"
  shift 3
  step "$label"
  if [ -f "$file" ]; then
    run_script "$file" "$@" || fail "$label failed"
  elif [ "$issue" = required ]; then
    fail "$file not found: the $label is required"
  else
    skip_missing "$file" "$issue"
  fi
}

# k.yaml validation: k_config is the only reader of k.yaml. This script never
# parses it and reads every value it needs through `k_config --get`.
k_config="packages/k_config/bin/k_config.dart"
check_script "k.yaml validation (k_config)" required "$k_config"

# kget <key>: the validated value of <key> in k.yaml, printed by k_config.
kget() {
  local value
  value="$(run_script "$k_config" --get "$1")" \
    || fail "could not read $1 from k.yaml through k_config"
  [ -n "$value" ] || fail "k_config printed an empty value for $1"
  printf '%s' "$value"
}

# Line coverage threshold of every package, in percent (#5): one
# "<package>\t<threshold>" line per workspace package, from its
# coverage.overrides entry or coverage.default.
thresholds="$(kget coverage.thresholds)" || exit 1
printf '%s\n' "$thresholds"

# threshold_of <package name>: the threshold printed by k_config.
threshold_of() {
  awk -F '\t' -v p="$1" '$1 == p { print $2; found = 1 } END { exit !found }' \
    <<<"$thresholds"
}
# Exact version of package:coverage (publisher tools.dart.dev) used to build
# the lcov report, so that local and CI runs use the same tool.
coverage_version="$(kget coverage.tool_version)" || exit 1

# Dependency publishers check (#4): exceptions come from k.yaml through
# package:k_config, the allowed publishers are fixed in k_config.
check_script "dependency publishers check" required "packages/k_publishers/bin/k_publishers.dart"

# ///-only comments check (#9, package from #20), on main: always required.
# k_comments reads its globs and exceptions from the comments section of
# k.yaml through k_config, so no value is passed here.
check_script "comments check" required "packages/k_comments/bin/k_comments.dart"

# Hardened CI rules for every workflow (#6): a YAML parse of
# .github/workflows checks pinned uses:, timeouts and permissions.
check_script "workflow hardening (#6)" required "packages/k_workflows/bin/k_workflows.dart"

step "workspace packages"
ws_json="$(dart pub workspace list --json)" \
  || fail "'dart pub workspace list --json' failed"
pkgs="$(jq -er '.packages[] | "\(.path)\t\(.name)"' <<<"$ws_json")" \
  || fail "could not read package paths from 'dart pub workspace list --json'"
[ -n "$pkgs" ] || fail "'dart pub workspace list --json' listed no packages"

packages=()
names=()
members=0
root_tests=false
while IFS=$'\t' read -r pkg name; do
  [ -n "$pkg" ] || continue
  abs="$(cd "$pkg" && pwd)" || fail "workspace package not found: $pkg"
  if [ "$abs" = "$root" ]; then pkg="."; else pkg="${abs#"$root"/}"; fi
  if [ "$pkg" = "." ] && [ ! -d lib ]; then
    if [ -n "$(find test -name '*_test.dart' -print -quit 2>/dev/null)" ]; then
      echo "Workspace root has no lib/: its tests run without coverage."
      root_tests=true
    else
      echo "Workspace root has no lib/ and no tests: not a tested package."
    fi
    continue
  fi
  [ "$pkg" = "." ] || members=$((members + 1))
  if [ -z "$(find "$pkg/test" -name '*_test.dart' -print -quit 2>/dev/null)" ]; then
    fail "package $pkg has no test/**/*_test.dart: every package needs tests"
  fi
  packages+=("$pkg")
  names+=("$name")
done <<<"$pkgs"
[ "$members" -gt 0 ] || fail "no workspace member package to test (only the root was listed)"
printf 'Packages: %s\n' "${packages[*]}"

if [ "$fast" = true ]; then
  skip "--fast: tests and coverage are left to the pre-push hook and CI."
  exit 0
fi

# executable_lines <file>: rough count of executable lines of a Dart file
# that the coverage report omitted (directives, comments and blanks excluded).
executable_lines() {
  awk '
    in_directive { if ($0 ~ /;/) in_directive = 0; next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(\/\/|\/\*|\*)/ { next }
    /^[[:space:]]*(import|export|part|library)([[:space:]]|;)/ {
      if ($0 !~ /;/) in_directive = 1
      next
    }
    { n++ } END { print n + 0 }
  ' "$1"
}

if [ "$root_tests" = true ]; then
  step "dart test (workspace root, no lib/)"
  dart test || fail "dart test failed in the workspace root"
fi

run dart pub global activate coverage "$coverage_version" >/dev/null

for i in "${!packages[@]}"; do
  pkg="${packages[$i]}"
  threshold="$(threshold_of "${names[$i]}")" \
    || fail "k_config printed no coverage threshold for package ${names[$i]}"
  [[ "$threshold" =~ ^(0|[1-9][0-9]*)$ ]] && [ "$threshold" -le 100 ] \
    || fail "invalid coverage threshold for ${names[$i]}: $threshold"
  step "dart test with coverage ($pkg, threshold ${threshold}%)"
  out="$root/.dart_tool/k_check/$(tr '/.' '__' <<<"$pkg")"
  rm -rf "$out"
  mkdir -p "$out"
  (cd "$pkg" && dart test --coverage="$out/raw") || fail "dart test failed in $pkg"
  (cd "$pkg" && dart pub global run coverage:format_coverage --lcov \
    --in="$out/raw" --out="$out/lcov.info" --report-on=lib --package=.) \
    || fail "format_coverage failed in $pkg"
  [ -f "$out/lcov.info" ] || fail "no lcov report produced for $pkg"

  totals="$(awk -F: '
    /^LH:/ { h += $2 } /^LF:/ { t += $2 } END { print h + 0, t + 0 }
  ' "$out/lcov.info")" || fail "could not read the lcov report of $pkg"
  read -r hit total <<<"$totals"
  [[ "$hit" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] \
    || fail "could not read the lcov totals of $pkg"

  # Every lib/ file must be in the report; a missing one counts as 0%.
  pkg_abs="$(cd "$pkg" && pwd)"
  lib_files="$(cd "$pkg_abs" && find ./lib -name '*.dart' -print | sort)" \
    || fail "could not list the lib/ files of $pkg"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    abs="$pkg_abs/${file#./}"
    if ! grep -qxF "SF:$abs" "$out/lcov.info"; then
      lines="$(executable_lines "$abs")"
      if [ "$lines" -gt 0 ]; then
        echo "Not loaded by any test (0%): ${abs#"$root"/} ($lines lines)"
        total=$((total + lines))
      fi
    fi
  done <<<"$lib_files"

  [ "$total" -gt 0 ] || fail "coverage: no executable lines in $pkg/lib"
  pct="$(awk -v h="$hit" -v t="$total" 'BEGIN { printf "%.2f", 100 * h / t }')"
  echo "Coverage $pkg: ${pct}% (${hit}/${total} lines), required ${threshold}%"
  # Written before the comparison so that a failing package is listed too.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- Coverage $pkg: ${pct}% (${hit}/${total} lines), required ${threshold}%" \
      >>"$GITHUB_STEP_SUMMARY"
  fi
  awk -v h="$hit" -v t="$total" -v m="$threshold" 'BEGIN { exit !(100 * h >= m * t) }' \
    || fail "coverage of $pkg is ${pct}%, below the threshold ${threshold}%"
done

echo
echo "All checks passed."
