#!/usr/bin/env bash
# Tests of tool/check.sh with a fake `dart` command (issue #16).
# Plain bash, no Dart SDK required.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/check.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
failed=0

# Fake commands shared by every test.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/dart" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  "pub workspace")
    [ -z "${FAKE_WS_FAIL:-}" ] || { echo "workspace error" >&2; exit 1; }
    [ -z "${FAKE_WS_EMPTY:-}" ] || exit 0
    [ ! -f .fake_ws_json ] || { cat .fake_ws_json; exit 0; }
    root="$PWD"
    printf '{"packages":['
    sep=""
    while IFS= read -r p; do
      printf '%s{"name":"%s","path":"%s"}' "$sep" "$(basename "$p")" "$root/$p"
      sep=","
    done <.fake_ws
    printf ']}\n'
    ;;
  "pub global")
    if [ "$3" = "run" ]; then
      for a in "$@"; do
        case "$a" in --out=*) out="${a#--out=}" ;; esac
      done
      sed "s|@PKG@|$PWD|g" fake.lcov >"$out"
    fi
    ;;
  "run k_config")
    echo "dart $*" >>.fake_runs
    [ -z "${FAKE_KCONFIG_FAIL:-}" ] || {
      echo "k.yaml: invalid YAML" >&2
      exit 1
    }
    if [ "${3:-}" = "--get" ] && [ "$4" = coverage.thresholds ]; then
      cat .fake_thresholds
    elif [ "${3:-}" = "--get" ]; then
      awk -v k="$4" '$1 == k { print $2 }' .fake_kconfig
    fi
    ;;
  "test "*)
    for a in "$@"; do
      case "$a" in --coverage=*) mkdir -p "${a#--coverage=}" ;; esac
    done
    ;;
  "pub get")
    echo "dart $*" >>.fake_runs
    [ -z "${FAKE_LOCK_FAIL:-}" ] || { echo "pubspec.lock is out of date" >&2; exit 65; }
    ;;
  "run "*)
    echo "dart $*" >>.fake_runs
    case "$2" in
      k_comments) [ -z "${FAKE_COMMENTS_FAIL:-}" ] || { echo "x.dart:1:1: line comment is not allowed"; exit 1; } ;;
      k_workflows) [ -z "${FAKE_WORKFLOWS_FAIL:-}" ] || { echo "w.yml: uses not pinned"; exit 1; } ;;
    esac
    ;;
  *) ;;
esac
FAKE
chmod +x "$bin/dart"

# add_pkg_script <repo> <name>: adds packages/<name>/bin/<name>.dart.
add_pkg_script() {
  mkdir -p "$1/packages/$2/bin"
  printf 'void main() {}\n' >"$1/packages/$2/bin/$2.dart"
}

# ran <repo> <pattern>: true when the fake dart recorded a matching run.
ran() { [ -f "$1/.fake_runs" ] && grep -qF -- "$2" "$1/.fake_runs"; }

# new_repo: a workspace with one fully covered package `packages/a`.
# Prints the repository path.
new_repo() {
  local d
  d="$(mktemp -d "$work/repo.XXXX")"
  mkdir -p "$d/tool" "$d/packages/a/lib" "$d/packages/a/test"
  cp "$check" "$d/tool/check.sh"
  mkdir -p "$d/.github/scripts"
  for t in .github/scripts/review_gate_test.sh .github/scripts/auto_merge_test.sh \
    .github/scripts/github_guard_test.sh .github/scripts/close_issues_test.sh \
    .github/scripts/closing_keywords_test.sh tool/check_test.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$d/$t"
  done
  printf 'name: ws\nworkspace:\n  - packages/a\n' >"$d/pubspec.yaml"
  printf 'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\n' >"$d/k.yaml"
  printf 'coverage.default 100\ncoverage.tool_version 1.16.0\n' >"$d/.fake_kconfig"
  printf 'a\t100\n' >"$d/.fake_thresholds"
  printf '.\npackages/a\n' >"$d/.fake_ws"
  printf 'int one() {\n  return 1;\n}\n' >"$d/packages/a/lib/a.dart"
  printf 'void main() {}\n' >"$d/packages/a/test/a_test.dart"
  printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:2\nend_of_record\n' >"$d/packages/a/fake.lcov"
  add_pkg_script "$d" k_comments
  add_pkg_script "$d" k_config
  add_pkg_script "$d" k_workflows
  add_pkg_script "$d" k_publishers
  echo "$d"
}

# expect <name> <exit: 0|1> <pattern> <repo>
expect() {
  local name="$1" want="$2" pattern="$3" repo="$4" out code=0
  out="$(cd "$repo" && PATH="$bin:$PATH" GITHUB_ACTIONS="${CI_MODE:-}" \
    bash tool/check.sh 2>&1)" || code=$?
  if { [ "$want" = 0 ] && [ "$code" = 0 ]; } || { [ "$want" = 1 ] && [ "$code" != 0 ]; }; then
    if grep -qF -- "$pattern" <<<"$out"; then
      echo "ok   - $name"
      pass=$((pass + 1))
      return
    fi
  fi
  echo "FAIL - $name (exit $code, expected '$pattern')"
  sed 's/^/       /' <<<"$out"
  failed=$((failed + 1))
}

r="$(new_repo)"
expect "fully covered workspace passes" 0 "All checks passed." "$r"

# Blocking 1: package list from `dart pub workspace list --json`.
r="$(new_repo)"
FAKE_WS_FAIL=1 expect "workspace list failure fails" 1 \
  "'dart pub workspace list --json' failed" "$r"

r="$(new_repo)"
mkdir -p "$r/packages/b/lib"
printf 'int two() => 2;\n' >"$r/packages/b/lib/b.dart"
printf 'packages/b\n' >>"$r/.fake_ws"
expect "package without test/ fails" 1 "package packages/b has no test" "$r"

r="$(new_repo)"
mkdir -p "$r/packages/b/test"
printf 'packages/b\n' >>"$r/.fake_ws"
expect "package with an empty test/ fails" 1 "packages/b has no test" "$r"

r="$(new_repo)"
mkdir -p "$r/lib"
printf 'int root() => 0;\n' >"$r/lib/root.dart"
expect "workspace root with lib/ and no tests fails" 1 "package . has no test" "$r"

# Blocking 2: every k.yaml value comes from k_config, never from parsing.
r="$(new_repo)"
printf 'a\t50\n' >"$r/.fake_thresholds"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:1\nend_of_record\n' >"$r/packages/a/fake.lcov"
expect "an override lets its package pass at its threshold" 0 "required 50%" "$r"

r="$(new_repo)"
for bad in 95.5 101 095 -1; do
  r="$(new_repo)"
  printf 'a\t%s\n' "$bad" >"$r/.fake_thresholds"
  expect "a threshold of $bad from k_config is rejected" 1 \
    "invalid coverage threshold for a: $bad" "$r"
done

r="$(new_repo)"
printf 'other\t100\n' >"$r/.fake_thresholds"
expect "a package without threshold fails" 1 \
  "k_config printed no coverage threshold for package a" "$r"

r="$(new_repo)"
printf 'a\tabc\n' >"$r/.fake_thresholds"
expect "a malformed threshold fails" 1 "invalid coverage threshold for a: abc" "$r"

r="$(new_repo)"
: >"$r/.fake_thresholds"
expect "no thresholds fails" 1 "k_config printed an empty value for coverage.thresholds" "$r"

r="$(new_repo)"
summary="$r/summary.md"
: >"$summary"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:1\nend_of_record\n' >"$r/packages/a/fake.lcov"
GITHUB_STEP_SUMMARY="$summary" expect "a failing package fails" 1 \
  "below the threshold 100%" "$r"
if grep -qF -- "- Coverage packages/a: 50.00% (1/2 lines), required 100%" "$summary"; then
  echo "ok   - job summary lists a failing package"
  pass=$((pass + 1))
else
  echo "FAIL - job summary lists a failing package"
  failed=$((failed + 1))
fi

# The workspace root with a lib/ is measured with its own threshold.
r="$(new_repo)"
mkdir -p "$r/lib" "$r/test"
printf 'int root() {\n  return 0;\n}\n' >"$r/lib/root.dart"
printf 'void main() {}\n' >"$r/test/root_test.dart"
printf 'SF:@PKG@/lib/root.dart\nLF:2\nLH:2\nend_of_record\n' >"$r/fake.lcov"
printf '{"packages":[{"name":"ws","path":"%s"},{"name":"a","path":"%s"}]}' \
  "$r" "$r/packages/a" >"$r/.fake_ws_json"
expect "a root without threshold fails" 1 \
  "k_config printed no coverage threshold for package ws" "$r"
printf 'a\t100\nws\t100\n' >"$r/.fake_thresholds"
expect "a root with lib/ gets its threshold" 0 "Coverage .: 100.00% (2/2 lines), required 100%" "$r"

r="$(new_repo)"
summary="$r/summary.md"
: >"$summary"
GITHUB_STEP_SUMMARY="$summary" expect "coverage is written to the job summary" 0 \
  "All checks passed." "$r"
if grep -qF -- "- Coverage packages/a: 100.00% (2/2 lines), required 100%" "$summary"; then
  echo "ok   - job summary lists the coverage"
  pass=$((pass + 1))
else
  echo "FAIL - job summary lists the coverage"
  failed=$((failed + 1))
fi

r="$(new_repo)"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:1\nend_of_record\n' >"$r/packages/a/fake.lcov"
expect "coverage below the threshold fails" 1 "below the threshold 100%" "$r"

r="$(new_repo)"
rm -r "$r/packages/k_config"
expect "missing k_config fails: k.yaml validation is required" 1 \
  "packages/k_config/bin/k_config.dart not found: the k.yaml validation (k_config) is required" "$r"

r="$(new_repo)"
FAKE_KCONFIG_FAIL=1 expect "an invalid k.yaml fails" 1 "FAIL: k.yaml validation (k_config) failed" "$r"

r="$(new_repo)"
printf 'coverage.default 100\n' >"$r/.fake_kconfig"
expect "a value k_config does not print fails" 1 \
  "k_config printed an empty value for coverage.tool_version" "$r"

r="$(new_repo)"
FAKE_WORKFLOWS_FAIL=1 expect "a workflow lint failure fails" 1 \
  "FAIL: workflow hardening (#6) failed" "$r"
if ! ran "$r" "dart run k_workflows"; then
  echo "FAIL - workflow lint runs by package name"; failed=$((failed + 1))
fi

r="$(new_repo)"
rm -r "$r/packages/k_workflows"
expect "a missing workflow lint fails" 1 \
  "packages/k_workflows/bin/k_workflows.dart not found: the workflow hardening (#6) is required" "$r"

r="$(new_repo)"
rm "$r/.github/scripts/auto_merge_test.sh"
expect "a missing bash test file fails" 1 \
  "bash test not found: .github/scripts/auto_merge_test.sh" "$r"

r="$(new_repo)"
expect "pub get enforces the lockfile" 0 "All checks passed." "$r"
if ! ran "$r" "dart pub get --enforce-lockfile"; then
  echo "FAIL - pub get enforces the lockfile (not invoked with --enforce-lockfile)"; failed=$((failed + 1))
fi

r="$(new_repo)"
FAKE_LOCK_FAIL=1 expect "out-of-sync lockfile fails" 1 \
  "FAIL: command failed: dart pub get --enforce-lockfile" "$r"

r="$(new_repo)"
: >"$r/k.yaml"
expect "k.yaml is never parsed by check.sh" 0 "All checks passed." "$r"
if ! ran "$r" "dart run k_config --get coverage.tool_version"; then
  echo "FAIL - k.yaml values are read by name through k_config --get"; failed=$((failed + 1))
fi

# Blocking 3: k.yaml is required and checked first.
r="$(new_repo)"
rm "$r/k.yaml"
expect "missing k.yaml fails first" 1 "FAIL: k.yaml is required" "$r"

r="$(new_repo)"
rm "$r/k.yaml" "$r/pubspec.yaml"
out="$(cd "$r" && PATH="$bin:$PATH" bash tool/check.sh 2>&1)" && code=0 || code=$?
if [ "$code" != 0 ] && [ "$(printf '%s\n' "$out" | tail -n 1)" = "FAIL: k.yaml is required" ] \
  && ! grep -q "==>" <<<"$out"; then
  echo "ok   - missing k.yaml fails before any other step"
  pass=$((pass + 1))
else
  echo "FAIL - missing k.yaml fails before any other step (exit $code)"
  sed 's/^/       /' <<<"$out"
  failed=$((failed + 1))
fi

r="$(new_repo)"
rm "$r/k.yaml"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:0\nend_of_record\n' >"$r/packages/a/fake.lcov"
for mode in "" true; do
  CI_MODE="$mode" expect "missing k.yaml is never green (CI=${mode:-false})" 1 \
    "k.yaml is required" "$r"
done

# Blocking 4: lib/ files that no test loads count as 0%.
r="$(new_repo)"
printf 'int b() {\n  return 2;\n}\n' >"$r/packages/a/lib/b.dart"
expect "untested lib file counts as 0%" 1 "coverage of packages/a is 40.00%" "$r"

r="$(new_repo)"
mkdir -p "$r/packages/a/lib/src"
printf 'int c() => 3;\n' >"$r/packages/a/lib/src/c.dart"
expect "untested nested lib file is reported" 1 \
  "Not loaded by any test (0%): packages/a/lib/src/c.dart" "$r"

r="$(new_repo)"
printf '/// Library.\nlibrary;\n\nexport "a.dart"\n    show one;\n' >"$r/packages/a/lib/all.dart"
expect "export-only lib file is not counted" 0 "All checks passed." "$r"

# The publishers check (#4) is required: a missing checker fails.
nopub="packages/k_publishers/bin/k_publishers.dart not found: the dependency publishers check is required"
r="$(new_repo)"; rm -r "$r/packages/k_publishers"
CI_MODE=true expect "missing publishers checker fails in CI" 1 "::error::$nopub" "$r"

r="$(new_repo)"; rm -r "$r/packages/k_publishers"
expect "missing publishers checker fails" 1 "$nopub" "$r"

# Repository script locations and invocation.
r="$(new_repo)"
expect "comments package runs by name" 0 "All checks passed." "$r"
if ! ran "$r" "dart run k_comments"; then
  echo "FAIL - comments package runs by name (not invoked as expected)"; failed=$((failed + 1))
fi

r="$(new_repo)"
add_pkg_script "$r" k_config
add_pkg_script "$r" k_publishers
expect "every script present passes" 0 "All checks passed." "$r"
if ! ran "$r" "dart run k_config" || ! ran "$r" "dart run k_publishers"; then
  echo "FAIL - every script present (k_config or k_publishers not run by name)"; failed=$((failed + 1))
fi

r="$(new_repo)"
FAKE_COMMENTS_FAIL=1 expect "comment violation fails" 1 "FAIL: comments check failed" "$r"

r="$(new_repo)"
rm -r "$r/packages/k_comments"
expect "missing comments checker fails while #9 is open" 1 \
  "packages/k_comments/bin/k_comments.dart not found: the comments check is required" "$r"

r="$(new_repo)"
rm -r "$r/packages/k_comments"
printf 'void main() {}\n' >"$r/tool/check_comments.dart"
expect "tool/check_comments.dart is not accepted" 1 "the comments check is required" "$r"
if ran "$r" "tool/check_comments.dart"; then
  echo "FAIL - tool/check_comments.dart was run"; failed=$((failed + 1))
fi

r="$(new_repo)"; rm -r "$r/packages/k_publishers"
printf 'void main() {}\n' >"$r/tool/check_publishers.dart"
expect "publishers: only the package location counts" 1 "$nopub" "$r"
if ran "$r" "tool/check_publishers.dart"; then
  echo "FAIL - tool/check_publishers.dart was run"; failed=$((failed + 1))
fi

r="$(new_repo)"
expect "publishers checker runs by name" 0 "All checks passed." "$r"
if ! ran "$r" "dart run k_publishers"; then
  echo "FAIL - publishers checker runs by name (not invoked)"; failed=$((failed + 1))
fi

r="$(new_repo)"
rm "$r/pubspec.yaml"
expect "no pubspec.yaml fails" 1 "pubspec.yaml is missing" "$r"

r="$(new_repo)"
: >"$r/.fake_ws"
FAKE_WS_EMPTY=1 expect "empty workspace list output fails" 1 \
  "could not read package paths" "$r"

r="$(new_repo)"
printf '{"packages":[]}' >"$r/.fake_ws_json"
expect "workspace with no packages fails" 1 "could not read package paths" "$r"

r="$(new_repo)"
printf '.\n' >"$r/.fake_ws"
expect "workspace listing only the root fails" 1 "only the root was listed" "$r"

r="$(new_repo)"
mkdir -p "$r/test"
printf 'void main() {}\n' >"$r/test/root_test.dart"
expect "root tests without lib/ run without coverage" 0 "dart test (workspace root, no lib/)" "$r"

# The Reviewer's cases on #13, against the real k_config when a Dart SDK is
# available: check.sh reads k.yaml only through it.
real_dart="$(command -v dart || true)"
if [ -n "$real_dart" ] && [ -f "$here/../packages/k_config/bin/k_config.dart" ]; then
  kroot="$(mktemp -d "$work/kroot.XXXX")"
  mkdir -p "$kroot/packages/a"
  printf 'name: ws\nworkspace:\n  - packages/a\n' >"$kroot/pubspec.yaml"
  printf 'name: a\nresolution: workspace\n' >"$kroot/packages/a/pubspec.yaml"
  kget_real() {
    (cd "$here/.." && "$real_dart" run packages/k_config/bin/k_config.dart --get "$1" "$kroot" 2>&1)
  }
  printf 'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\ndependencies: {exceptions: {}, registry_timeout_seconds: 30}\ncomments: {include: ["**.dart"], exclude: [], exceptions: []}\nclose_issues: {lookback_hours: 72}\nworkflows: {max_timeout_minutes: 20, write_scopes: []}\n' >"$kroot/k.yaml"
  if got="$(kget_real coverage.tool_version)" && [ "$got" = "1.16.0" ]; then
    echo "ok   - flow style k.yaml is read by k_config"
    pass=$((pass + 1))
  else
    echo "FAIL - flow style k.yaml is read by k_config: $got"
    failed=$((failed + 1))
  fi
  printf 'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\ndependencies: {exceptions: {}, registry_timeout_seconds: 30}\ncomments: {include: ["**.dart"], exclude: [], exceptions: []}\nclose_issues: {lookback_hours: 72}\nworkflows: {max_timeout_minutes: 20, write_scopes: []}\n' >"$kroot/k.yaml"
  if got="$(kget_real coverage.thresholds)" && [ "$got" = "$(printf 'a\t100\nws\t100')" ]; then
    echo "ok   - k_config gives the workspace root a threshold"
    pass=$((pass + 1))
  else
    echo "FAIL - k_config gives the workspace root a threshold: $got"
    failed=$((failed + 1))
  fi
  # The Guardian's coverage.default cases, now enforced by k_config.
  for bad in '"100"' "'100'" abc 101 100.0 -1 '' 1e2 0x64 +100; do
    printf 'coverage:\n  default: %s\n  tool_version: 1.16.0\n  overrides: {}\ndependencies: {exceptions: {}, registry_timeout_seconds: 30}\ncomments: {include: ["**.dart"], exclude: [], exceptions: []}\nclose_issues: {lookback_hours: 72}\nworkflows: {max_timeout_minutes: 20, write_scopes: []}\n' "$bad" >"$kroot/k.yaml"
    if got="$(kget_real coverage.default)"; then
      echo "FAIL - coverage.default $bad is rejected: $got"
      failed=$((failed + 1))
    elif grep -qF "coverage.default: must be an integer from 0 to 100" <<<"$got"; then
      echo "ok   - coverage.default ${bad:-(empty)} is rejected"
      pass=$((pass + 1))
    else
      echo "FAIL - coverage.default ${bad:-(empty)} is rejected with the wrong message: $got"
      failed=$((failed + 1))
    fi
  done
  printf 'coverage:\n  default: 50 # comment\n  tool_version: 1.16.0\n  overrides: {}\ndependencies: {exceptions: {}, registry_timeout_seconds: 30}\ncomments: {include: ["**.dart"], exclude: [], exceptions: []}\nclose_issues: {lookback_hours: 72}\nworkflows: {max_timeout_minutes: 20, write_scopes: []}\n' >"$kroot/k.yaml"
  if got="$(kget_real coverage.default)" && [ "$got" = 50 ]; then
    echo "ok   - integer coverage.default with a comment is used"
    pass=$((pass + 1))
  else
    echo "FAIL - integer coverage.default with a comment is used: $got"
    failed=$((failed + 1))
  fi
  printf 'coverage:\n  default: 100\n  tool_version: "1.16.0\n  overrides: {}\ndependencies: {exceptions: {}, registry_timeout_seconds: 30}\ncomments: {include: ["**.dart"], exclude: [], exceptions: []}\nclose_issues: {lookback_hours: 72}\nworkflows: {max_timeout_minutes: 20, write_scopes: []}\n' >"$kroot/k.yaml"
  if got="$(kget_real coverage.tool_version)"; then
    echo "FAIL - unbalanced quote in k.yaml is rejected: $got"
    failed=$((failed + 1))
  else
    echo "ok   - unbalanced quote in k.yaml is rejected"
    pass=$((pass + 1))
  fi
else
  echo "SKIP - real k_config cases (no Dart SDK)"
fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
