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

# Version of package:coverage (publisher tools.dart.dev) used to build the
# lcov report. Pinned so local and CI runs use the same tool.
# TODO(#13): move coverage_version to k.yaml once k_config lands.
coverage_version="1.16.0"

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

step "bash tests"
for t in .github/scripts/review_gate_test.sh .github/scripts/github_guard_test.sh tool/check_test.sh; do
  if [ -f "$t" ]; then
    bash "$t" || fail "bash tests failed: $t"
  fi
done

if [ ! -f pubspec.yaml ]; then
  fail "pubspec.yaml is missing at the repository root"
fi

# Coverage threshold: coverage.default in k.yaml, a YAML integer in [0, 100].
# A missing k.yaml or key falls back to 100% and still fails the job.
threshold_error=""
threshold=""
if [ -f k.yaml ]; then
  threshold="$(awk '
    /^[^[:space:]#]/ { in_cov = ($0 ~ /^coverage:/) }
    in_cov && /^[[:space:]]+default:/ {
      sub(/^[[:space:]]+default:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, "")
      sub(/[[:space:]]+$/, ""); print; found = 1; exit
    }
    END { if (!found) print "<missing>" }
  ' k.yaml)"
fi
if [ -z "$threshold" ] || [ "$threshold" = "<missing>" ]; then
  threshold_error="k.yaml with coverage.default is required; defaulting to 100%"
  threshold=100
elif ! [[ "$threshold" =~ ^(0|[1-9][0-9]*)$ ]] || [ "$threshold" -gt 100 ]; then
  fail "k.yaml coverage.default must be a YAML integer from 0 to 100, got: $threshold"
fi

step "dart pub get"
run dart pub get

step "dart format"
dart format --output=none --set-exit-if-changed . \
  || fail "code is not formatted; run 'dart format .'"

step "dart analyze --fatal-infos"
dart analyze --fatal-infos || fail "dart analyze reported diagnostics"

# Repository scripts introduced by other issues. Each one is skipped while
# its issue is open, and fails the job once the issue is closed.
# TODO(#13): k_config lands with PR #13.
k_config="packages/k_config/bin/k_config.dart"
step "k.yaml validation (k_config)"
if [ -f "$k_config" ]; then
  dart run "$k_config" || fail "k.yaml validation failed"
else
  skip_missing "$k_config" 13
fi

# TODO(#4): dependency publishers check.
publishers="tool/check_publishers.dart"
step "dependency publishers check"
if [ -f "$publishers" ]; then
  dart run "$publishers" || fail "dependency publishers check failed"
else
  skip_missing "$publishers" 4
fi

# TODO(#9): ///-only comments check.
comments="tool/check_comments.dart"
step "comments check"
if [ -f "$comments" ]; then
  dart run "$comments" || fail "comments check failed"
else
  skip_missing "$comments" 9
fi

step "workspace packages"
ws_json="$(dart pub workspace list --json)" \
  || fail "'dart pub workspace list --json' failed"
pkgs="$(jq -er '.packages[].path' <<<"$ws_json")" \
  || fail "could not read package paths from 'dart pub workspace list --json'"
[ -n "$pkgs" ] || fail "'dart pub workspace list --json' listed no packages"

packages=()
members=0
root_tests=false
while IFS= read -r pkg; do
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
done <<<"$pkgs"
[ "$members" -gt 0 ] || fail "no workspace member package to test (only the root was listed)"
printf 'Packages: %s\n' "${packages[*]}"

if [ "$fast" = true ]; then
  skip "--fast: tests and coverage are left to the pre-push hook and CI."
  [ -z "$threshold_error" ] || fail "$threshold_error"
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

# TODO(#5): per-package coverage.overrides are not applied yet; only
# coverage.default is enforced here.
for pkg in "${packages[@]}"; do
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
  awk -v h="$hit" -v t="$total" -v m="$threshold" 'BEGIN { exit !(100 * h >= m * t) }' \
    || fail "coverage of $pkg is ${pct}%, below the threshold ${threshold}%"
done

[ -z "$threshold_error" ] || fail "$threshold_error"

echo
echo "All checks passed."
