#!/usr/bin/env bash
# Single source of the local and CI checks (issue #16).
# Used by the `test` CI job and by the git hooks in tool/hooks.
#
# Usage: tool/check.sh [--fast]
#   --fast  skip `dart test` and coverage (used by the pre-commit hook;
#           the pre-push hook and CI always run the full check).
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
skip() { printf 'SKIP: %s\n' "$*"; }
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; fi
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
run() { "$@" || fail "command failed: $*"; }

step "review-gate script tests"
run bash .github/scripts/review_gate_test.sh

if [ ! -f pubspec.yaml ]; then
  skip "no pubspec.yaml: no Dart checks to run."
  exit 0
fi

step "dart pub get"
run dart pub get

step "dart format"
dart format --output=none --set-exit-if-changed . \
  || fail "code is not formatted; run 'dart format .'"

step "dart analyze --fatal-infos"
dart analyze --fatal-infos || fail "dart analyze reported diagnostics"

step "require tests"
if [ -z "$(find . -name .dart_tool -prune -o -name '*_test.dart' -print -quit)" ]; then
  fail "pubspec.yaml exists but no *_test.dart file was found"
fi

# Repository scripts introduced by other issues. Each one is skipped with an
# explicit message until its file exists on main.
# TODO(#13): k_config lands with PR #13.
k_config="packages/k_config/bin/k_config.dart"
step "k.yaml validation (k_config)"
if [ -f "$k_config" ]; then
  dart run "$k_config" || fail "k.yaml validation failed"
else
  skip "$k_config not found (issue #13 not merged yet)."
fi

# TODO(#4): dependency publishers check.
publishers="tool/check_publishers.dart"
step "dependency publishers check"
if [ -f "$publishers" ]; then
  dart run "$publishers" || fail "dependency publishers check failed"
else
  skip "$publishers not found (issue #4 not merged yet)."
fi

# TODO(#9): ///-only comments check.
comments="tool/check_comments.dart"
step "comments check"
if [ -f "$comments" ]; then
  dart run "$comments" || fail "comments check failed"
else
  skip "$comments not found (issue #9 not merged yet)."
fi

if [ "$fast" = true ]; then
  skip "--fast: dart test and coverage are left to the pre-push hook and CI."
  exit 0
fi

# Coverage threshold: read from k.yaml (coverage.default), never hard-coded.
threshold=""
if [ -f k.yaml ]; then
  threshold="$(awk '
    /^[^[:space:]#]/ { in_cov = ($0 ~ /^coverage:/) }
    in_cov && /^[[:space:]]+default:/ { sub(/.*default:[[:space:]]*/, ""); sub(/[[:space:]#].*/, ""); print; exit }
  ' k.yaml)"
  [ -n "$threshold" ] || fail "k.yaml has no coverage.default value"
fi

# Every package with a test/ directory (the root package or workspace members).
mapfile -t packages < <(
  find . -path ./.dart_tool -prune -o -path '*/.dart_tool' -prune -o \
    -name pubspec.yaml -print | xargs -n1 dirname | sort | while read -r dir; do
      [ -d "$dir/test" ] && echo "$dir"
    done
)
[ "${#packages[@]}" -gt 0 ] || fail "no package with a test/ directory was found"

if [ -z "$threshold" ]; then
  skip "coverage: no k.yaml yet (issue #13), threshold check skipped."
fi

# TODO(#5): per-package coverage.overrides are not applied yet; only
# coverage.default is enforced here.
for pkg in "${packages[@]}"; do
  if [ -z "$threshold" ]; then
    step "dart test ($pkg)"
    (cd "$pkg" && dart test) || fail "dart test failed in $pkg"
    continue
  fi
  step "dart test with coverage ($pkg, threshold ${threshold}% from k.yaml)"
  lcov="$root/.dart_tool/k_check/$(echo "$pkg" | tr '/.' '__').lcov.info"
  mkdir -p "$(dirname "$lcov")"
  (cd "$pkg" && dart test --coverage-path="$lcov") || fail "dart test failed in $pkg"
  read -r hit total < <(awk -F: '
    /^LH:/ { h += $2 } /^LF:/ { t += $2 } END { print h + 0, t + 0 }
  ' "$lcov")
  [ "$total" -gt 0 ] || fail "coverage: no instrumented lines in $pkg"
  pct="$(awk -v h="$hit" -v t="$total" 'BEGIN { printf "%.2f", 100 * h / t }')"
  echo "Coverage $pkg: ${pct}% (${hit}/${total} lines), required ${threshold}%"
  awk -v p="$pct" -v m="$threshold" 'BEGIN { exit !(p + 0 >= m + 0) }' \
    || fail "coverage of $pkg is ${pct}%, below the k.yaml threshold ${threshold}%"
done

echo
echo "All checks passed."
