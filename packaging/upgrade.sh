#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: packaging/upgrade.sh apply ARCHIVE --sha256 DIGEST --channel development|preview|stable'
  echo '       valpo-upgrade recover'
  exit 0
fi
[[ "$EUID" == 0 ]] || { echo 'Run the host updater as root' >&2; exit 1; }
updater=/var/lib/valpo-updater
install -d -m 0755 "$updater"
exec 9>"$updater/upgrade.lock"
flock -n 9 || { echo 'Another upgrade is running' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$updater/pending.json" ]]; then
  [[ "${1:-}" == recover ]] || { echo 'Interrupted upgrade; run valpo-upgrade recover' >&2; exit 1; }
elif [[ "$script_dir" != "$updater/tooling" ]]; then
  install -d -m 0700 "$updater/tooling"
  install -m 0600 "$script_dir/upgrade/upgrader.rb" "$updater/tooling/upgrader.rb"
  install -m 0600 "$script_dir/upgrade/probe.rb" "$updater/tooling/probe.rb"
  install -m 0700 "${BASH_SOURCE[0]}" "$updater/tooling/upgrade.sh"
fi
if [[ ! -d "$updater/runtime/ruby" ]]; then
  # Preserve a separate runtime before touching either application release.
  # No application gems, Bundler configuration, or current symlink is used.
  ruby_source=/opt/valpo/current/runtime/ruby
  if [[ ! -x "$ruby_source/bin/ruby" ]]; then
    ruby_source=/var/lib/valpo/.local/share/mise/installs/ruby/4.0.5
  fi
  [[ -x "$ruby_source/bin/ruby" ]] || { echo 'Installed Ruby runtime is missing' >&2; exit 1; }
  install -d -m 0700 "$updater/runtime"
  temporary="$(mktemp -d "$updater/runtime/stage.XXXXXX")"
  trap 'rm -rf "$temporary"' EXIT
  cp -a "$ruby_source/." "$temporary/"
  chown -R root:root "$temporary"
  chmod -R go-w "$temporary"
  env -i PATH=/usr/bin:/bin HOME=/root "$temporary/bin/ruby" -rjson -ropen3 -rrubygems/package -e 'puts "Recovery Ruby ready"'
  mv "$temporary" "$updater/runtime/ruby"
  sync -f "$updater/runtime"
  trap - EXIT
fi
printf '%s\n' '#!/bin/sh' 'exec /var/lib/valpo-updater/tooling/upgrade.sh "$@"' > "$updater/launcher.next"
install -m 0755 "$updater/launcher.next" /usr/local/bin/valpo-upgrade
rm "$updater/launcher.next"
exec env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root LANG=C.UTF-8 VALPO_UPGRADE_LOCK_FD=9 \
  "$updater/runtime/ruby/bin/ruby" "$updater/tooling/upgrader.rb" "$@"
