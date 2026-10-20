#!/usr/bin/env bash
# Installs the versioned git hooks of tool/hooks (issue #16).
#
# Usage: tool/install_hooks.sh [--force]
#   --force  replace an existing core.hooksPath or local .git/hooks scripts.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="tool/hooks"

force=false
for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    *) echo "install_hooks.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

current="$(git -C "$root" config --get core.hooksPath || true)"
if [ "$current" = "$target" ]; then
  echo "Git hooks already installed: core.hooksPath=$target"
  exit 0
fi

problems=()
if [ -n "$current" ]; then
  problems+=("core.hooksPath is already set to '$current'")
fi
hooks_dir="$(git -C "$root" rev-parse --path-format=absolute --git-path hooks)"
if [ -d "$hooks_dir" ]; then
  while IFS= read -r hook; do
    [ -n "$hook" ] && problems+=("existing hook would be disabled: $hook")
  done <<<"$(find "$hooks_dir" -maxdepth 1 -type f ! -name '*.sample' -print)"
fi

if [ "${#problems[@]}" -gt 0 ]; then
  for p in "${problems[@]}"; do echo "WARNING: $p" >&2; done
  if [ "$force" = false ]; then
    echo "Nothing changed. Re-run with --force to use $target anyway." >&2
    exit 1
  fi
fi

git -C "$root" config core.hooksPath "$target"
echo "Git hooks installed: core.hooksPath=$target"
