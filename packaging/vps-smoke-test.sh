#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec mise exec -- ruby "${repo_root}/packaging/vps_smoke_test.rb" "$@"
