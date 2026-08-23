#!/usr/bin/env bash
set -euo pipefail

launcher_path="$(readlink -f "${BASH_SOURCE[0]}")"
release_root="$(cd "$(dirname "$launcher_path")/.." && pwd)"
command_name="$(basename "${BASH_SOURCE[0]}")"

case "$command_name" in
  valpo|valpo-api|valpo-maintenance|valpo-migrate|valpo-worker)
    entrypoint="${release_root}/exe/${command_name}"
    ;;
  *)
    printf 'Unknown Valpo release launcher: %s\n' "$command_name" >&2
    exit 1
    ;;
esac

export PATH="${release_root}/tools:${release_root}/runtime/ruby/bin:${PATH}"
export RUBYLIB="${release_root}/bundle"
export BUNDLE_GEMFILE="${release_root}/Gemfile"

exec "${release_root}/runtime/ruby/bin/ruby" "$entrypoint" "$@"
