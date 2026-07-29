#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v mise >/dev/null 2>&1; then
  exec mise exec -- ruby "${repo_root}/packaging/vps_smoke_test.rb" "$@"
fi

exec ruby "${repo_root}/packaging/vps_smoke_test.rb" "$@"
