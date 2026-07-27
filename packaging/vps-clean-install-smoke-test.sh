#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: packaging/vps-clean-install-smoke-test.sh USER@HOST DOMAIN_SUFFIX --confirm-destroy-valpo [smoke-test options]

Completely removes Valpo from a VPS, verifies that its resources are gone, then
copies the current private checkout and runs the full installation smoke test.
Shared host packages such as Docker and Caddy are retained.

The destructive confirmation flag is required. All remaining options are passed
to packaging/vps-smoke-test.sh; --skip-deps is not allowed.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -lt 3 ]]; then
  usage
  exit 64
fi

ssh_target="$1"
domain_suffix="$2"
shift 2

confirmed=0
smoke_options=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-destroy-valpo)
      confirmed=1
      shift
      ;;
    --skip-deps)
      printf '%s\n' '--skip-deps is incompatible with a clean-install smoke test' >&2
      exit 64
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      smoke_options+=("$1")
      shift
      ;;
  esac
done

if [[ "$confirmed" -ne 1 ]]; then
  printf '%s\n' 'Refusing to delete Valpo without --confirm-destroy-valpo' >&2
  exit 64
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_uninstaller="/tmp/valpo-uninstall-$$.sh"

cleanup() {
  # The generated remote path is intentionally expanded on the client.
  # shellcheck disable=SC2029
  ssh "$ssh_target" "rm -f '$remote_uninstaller'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '[clean-install] copying uninstaller to %s\n' "$ssh_target"
rsync -az "${repo_root}/packaging/uninstall.sh" "${ssh_target}:${remote_uninstaller}"

printf '[clean-install] removing existing Valpo installation\n'
# The generated remote path is intentionally expanded on the client.
# shellcheck disable=SC2029
ssh "$ssh_target" "bash '$remote_uninstaller'"

printf '[clean-install] verifying clean state\n'
ssh "$ssh_target" 'test ! -e /opt/valpo &&
  test ! -e /var/lib/valpo &&
  test ! -e /var/log/valpo &&
  test ! -e /etc/valpo &&
  test ! -e /usr/local/bin/valpo &&
  test ! -e /etc/systemd/system/valpo-api.service &&
  test ! -e /etc/systemd/system/valpo-worker.service &&
  test ! -e /etc/systemd/system/valpo-migrate.service &&
  test ! -e /etc/systemd/system/valpo-maintenance.service &&
  test ! -e /etc/systemd/system/valpo-maintenance.timer &&
  ! id valpo >/dev/null 2>&1 &&
  test -z "$(docker network ls -q --filter label=valpo.owned=true)" &&
  test -z "$(docker ps -aq --filter label=valpo.owned=true)" &&
  test -z "$(docker volume ls -q --filter label=valpo.owned=true)" &&
  ! grep -q "VALPO\|valpo.caddy" /etc/caddy/Caddyfile'

printf '[clean-install] running full installation smoke test\n'
smoke_options+=(--full-install)
"${repo_root}/packaging/vps-smoke-test.sh" \
  "$ssh_target" \
  "$domain_suffix" \
  "${smoke_options[@]}"
