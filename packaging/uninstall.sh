#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: packaging/uninstall.sh

Removes Valpo-owned services, containers, volumes, images, state, and host files.
Shared host packages such as Docker and Caddy are retained.

Options:
  -h, --help  Show this help
USAGE
}

log() {
  printf '[valpo-uninstall] %s\n' "$*"
}

fail() {
  printf '[valpo-uninstall] ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || fail "This uninstaller must run as root"

log "Stopping Valpo services"
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now valpo-api.service valpo-worker.service 2>/dev/null || true
  systemctl stop valpo-migrate.service 2>/dev/null || true
fi

if command -v docker >/dev/null 2>&1; then
  log "Removing Valpo Docker resources"
  docker ps -aq --filter label=valpo.managed=true | xargs -r docker rm -f
  docker volume ls -q | grep '^valpo-' | xargs -r docker volume rm -f || true
  docker network rm valpo >/dev/null 2>&1 || true
  docker image ls --filter 'reference=valpo/*' -q | sort -u | xargs -r docker image rm -f
fi

if [[ -f /etc/caddy/Caddyfile ]]; then
  log "Removing Valpo Caddy import"
  sed -i '/^# BEGIN VALPO$/,/^# END VALPO$/d' /etc/caddy/Caddyfile
  sed -i '\|^[[:space:]]*import /var/lib/valpo/caddy/valpo\.caddy[[:space:]]*$|d' /etc/caddy/Caddyfile
  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config /etc/caddy/Caddyfile
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart caddy.service
  fi
fi

log "Removing Valpo host files and account"
rm -f \
  /etc/systemd/system/valpo-api.service \
  /etc/systemd/system/valpo-worker.service \
  /etc/systemd/system/valpo-migrate.service \
  /usr/local/bin/valpo
rm -rf /etc/valpo /opt/valpo /var/lib/valpo /var/log/valpo

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl reset-failed
fi
userdel valpo 2>/dev/null || true
groupdel valpo 2>/dev/null || true

log "Valpo uninstall complete"
