#!/usr/bin/env bash
# Installs the versioned git hooks of tool/hooks (issue #16).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$root" config core.hooksPath tool/hooks
echo "Git hooks installed: core.hooksPath=tool/hooks"
