#!/usr/bin/env bash
set -euo pipefail

[[ "${VALPO_UPGRADE_ACCEPTANCE:-}" == 1 && "$EUID" == 0 ]] || {
  echo 'Only run on a disposable installed host with VALPO_UPGRADE_ACCEPTANCE=1 as root' >&2
  exit 1
}
archive="$(realpath "${1:?release artifact required}")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
updater="$script_dir/../upgrade.sh"
version="$(basename "$archive" | sed -E 's/^valpo-(.+)-linux-(amd64|arm64)\.tar\.zst$/\1/')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a final release artifact' >&2; exit 1; }
candidate="/opt/valpo/releases/$version"
[[ ! -e "$candidate" && ! -e /var/lib/valpo-updater/pending.json ]] || { echo 'Acceptance requires an unstaged candidate and no pending upgrade' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
containers_before="$(docker ps --filter label=valpo.owned=true --format '{{.ID}}' | sort)"
mkdir "$work/payload" "$work/fault"
tar --zstd -xf "$archive" -C "$work/payload"
payload="$work/payload/opt/valpo/releases/$version"
cp "$payload/exe/valpo-migrate" "$work/migrate"
cp "$payload/exe/valpo-api" "$work/api"
fault="$work/fault/$(basename "$archive")"

# Simulate a migration that committed an incompatible schema before failing.
cat >> "$payload/exe/valpo-migrate" <<'RUBY'
Valpo::Database.connect(Valpo::Config.load)[:schema_info].update(version: 999)
abort "Injected migration failure after schema mutation"
RUBY
tar --zstd -cf "$fault" -C "$work/payload" "opt/valpo/releases/$version"
if "$updater" apply "$fault" --sha256 "$(sha256sum "$fault" | cut -d' ' -f1)" --channel development > "$work/failure.log" 2>&1; then
  echo 'Injected migration failure unexpectedly activated' >&2
  exit 1
fi
cat "$work/failure.log"
grep -q 'Injected migration failure' "$work/failure.log"
[[ ! -e /var/lib/valpo-updater/pending.json ]]
systemctl is-active --quiet valpo-api valpo-worker
[[ "$(readlink -f /opt/valpo/current)" != "$candidate" ]]
# Only remove the deliberately faulty, inactive release on this disposable host.
rm -rf "$candidate"
rm "/var/lib/valpo-updater/artifacts/$version.json"

cp "$work/migrate" "$payload/exe/valpo-migrate"
printf '%s\n' 'abort "Injected candidate API failure"' > "$payload/exe/valpo-api"
tar --zstd -cf "$fault" -C "$work/payload" "opt/valpo/releases/$version"
if "$updater" apply "$fault" --sha256 "$(sha256sum "$fault" | cut -d' ' -f1)" --channel development > "$work/failure.log" 2>&1; then
  echo 'Injected readiness failure unexpectedly activated' >&2
  exit 1
fi
cat "$work/failure.log"
grep -q 'Candidate API exited before readiness' "$work/failure.log"
[[ ! -e /var/lib/valpo-updater/pending.json ]]
systemctl is-active --quiet valpo-api valpo-worker
[[ "$(readlink -f /opt/valpo/current)" != "$candidate" ]]
rm -rf "$candidate"
rm "/var/lib/valpo-updater/artifacts/$version.json"

"$updater" apply "$archive" --sha256 "$(sha256sum "$archive" | cut -d' ' -f1)" --channel development
[[ "$(readlink -f /opt/valpo/current)" == "$candidate" ]]
systemctl is-active --quiet valpo-api valpo-worker
containers_after="$(docker ps --filter label=valpo.owned=true --format '{{.ID}}' | sort)"
[[ "$containers_before" == "$containers_after" ]]
echo 'Upgrade acceptance passed: migration rollback, readiness rollback, activation, unchanged application containers'
