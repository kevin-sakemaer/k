#!/usr/bin/env bash
# Tests of tool/check.sh with fake `dart` and `gh` commands (issue #16).
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
  "test "*)
    for a in "$@"; do
      case "$a" in --coverage=*) mkdir -p "${a#--coverage=}" ;; esac
    done
    ;;
  *) ;;
esac
FAKE
cat >"$bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
echo "${FAKE_GH_STATE:-OPEN}"
FAKE
chmod +x "$bin/dart" "$bin/gh"

# new_repo: a workspace with one fully covered package `packages/a`.
# Prints the repository path.
new_repo() {
  local d
  d="$(mktemp -d "$work/repo.XXXX")"
  mkdir -p "$d/tool" "$d/packages/a/lib" "$d/packages/a/test"
  cp "$check" "$d/tool/check.sh"
  printf 'name: ws\nworkspace:\n  - packages/a\n' >"$d/pubspec.yaml"
  printf 'coverage:\n  default: 100\n  overrides: {}\n' >"$d/k.yaml"
  printf '.\npackages/a\n' >"$d/.fake_ws"
  printf 'int one() {\n  return 1;\n}\n' >"$d/packages/a/lib/a.dart"
  printf 'void main() {}\n' >"$d/packages/a/test/a_test.dart"
  printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:2\nend_of_record\n' >"$d/packages/a/fake.lcov"
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

# Blocking 2: threshold validation.
for bad in '"100"' "'100'" abc 101 100.0 -1 '' 1e2; do
  r="$(new_repo)"
  printf 'coverage:\n  default: %s\n' "$bad" >"$r/k.yaml"
  if [ -z "$bad" ]; then
    expect "empty coverage.default fails" 1 "coverage.default is required" "$r"
  else
    expect "coverage.default $bad is rejected" 1 "must be a YAML integer from 0 to 100" "$r"
  fi
done

r="$(new_repo)"
printf 'coverage:\n  default: 50 # comment\n' >"$r/k.yaml"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:1\nend_of_record\n' >"$r/packages/a/fake.lcov"
expect "integer threshold with a comment is used" 0 "required 50%" "$r"

r="$(new_repo)"
printf 'coverage:\n  default: 100\n' >"$r/k.yaml"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:1\nend_of_record\n' >"$r/packages/a/fake.lcov"
expect "coverage below the threshold fails" 1 "below the threshold 100%" "$r"

# Blocking 3: k.yaml and coverage.default are required.
r="$(new_repo)"
rm "$r/k.yaml"
expect "missing k.yaml fails with a 100% default" 1 \
  "k.yaml with coverage.default is required; defaulting to 100%" "$r"

r="$(new_repo)"
rm "$r/k.yaml"
printf 'SF:@PKG@/lib/a.dart\nLF:2\nLH:1\nend_of_record\n' >"$r/packages/a/fake.lcov"
expect "missing k.yaml still enforces 100%" 1 "below the threshold 100%" "$r"

r="$(new_repo)"
printf 'coverage:\n  overrides: {}\ncomments:\n  default: 0\n' >"$r/k.yaml"
expect "missing coverage.default fails" 1 \
  "k.yaml with coverage.default is required; defaulting to 100%" "$r"

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

# Skips of repository scripts.
r="$(new_repo)"
CI_MODE=true expect "skip emits a CI warning" 0 \
  "::warning::SKIP: packages/k_config/bin/k_config.dart not found" "$r"

r="$(new_repo)"
FAKE_GH_STATE=CLOSED expect "skip fails once the issue is closed" 1 \
  "issue #13 is CLOSED" "$r"

r="$(new_repo)"
FAKE_GH_FAIL=1 expect "unknown issue state only warns locally" 0 \
  "state of issue #13 could not be checked" "$r"

r="$(new_repo)"
FAKE_GH_FAIL=1 CI_MODE=true expect "unknown issue state fails in CI" 1 \
  "::error::packages/k_config/bin/k_config.dart not found and the state of issue #13 could not be checked" "$r"

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

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
