#!/usr/bin/env bash
set -euo pipefail

RUBY_VERSION="${VALPO_RUBY_VERSION:-4.0.5}"
VALPO_USER="${VALPO_USER:-valpo}"
VALPO_GROUP="${VALPO_GROUP:-valpo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="/opt/valpo"
CONFIG_PATH="/etc/valpo/valpo.yml"
STATE_DIR="/var/lib/valpo"
LOG_DIR="/var/log/valpo"
SKIP_DEPS=0
NO_START=0

usage() {
  cat <<USAGE
Usage: sudo packaging/install.sh [options]

Options:
  --source PATH      Source checkout to install from (default: repo root)
  --prefix PATH      Install source into PATH (default: /opt/valpo)
  --config PATH      Write Valpo config to PATH (default: /etc/valpo/valpo.yml)
  --state-dir PATH   Store Valpo state under PATH (default: /var/lib/valpo)
  --skip-deps        Do not install apt packages, mise, Ruby, or gems
  --no-start         Do not enable or start systemd services
  -h, --help         Show this help
USAGE
}

log() {
  printf '[valpo-install] %s\n' "$*"
}

fail() {
  printf '[valpo-install] ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="$2"
      shift 2
      ;;
    --skip-deps)
      SKIP_DEPS=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
CONFIG_DIR="$(dirname "$CONFIG_PATH")"
CADDY_GENERATED_PATH="${STATE_DIR}/caddy/valpo.caddy"
CADDY_RELOAD_CONFIG_PATH="/etc/caddy/Caddyfile"
MISE_BIN="${STATE_DIR}/.local/bin/mise"

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "This installer must run as root. Try: sudo packaging/install.sh"
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This installer currently supports Ubuntu only"
}

install_packages() {
  [[ "$SKIP_DEPS" -eq 0 ]] || return 0

  command -v apt-get >/dev/null 2>&1 || fail "apt-get is required on Ubuntu"
  export DEBIAN_FRONTEND=noninteractive
  log "Installing runtime packages"
  apt-get update
  apt-get install -y \
    build-essential \
    ca-certificates \
    caddy \
    curl \
    docker.io \
    git \
    gnupg \
    lsb-release \
    rsync \
    tar \
    unzip \
    xz-utils
}

ensure_user_and_dirs() {
  if ! getent group "$VALPO_GROUP" >/dev/null; then
    log "Creating group ${VALPO_GROUP}"
    groupadd --system "$VALPO_GROUP"
  fi

  if ! id -u "$VALPO_USER" >/dev/null 2>&1; then
    log "Creating user ${VALPO_USER}"
    useradd --system --gid "$VALPO_GROUP" --home-dir "$STATE_DIR" --shell /usr/sbin/nologin --no-create-home "$VALPO_USER"
  fi

  if getent group docker >/dev/null; then
    usermod -aG docker "$VALPO_USER"
  fi

  install -d -m 0755 "$PREFIX"
  install -d -m 0755 "$CONFIG_DIR" /etc/caddy /etc/systemd/system
  install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0755 "$STATE_DIR" "${STATE_DIR}/caddy"
  install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0750 "${STATE_DIR}/bundle" "$LOG_DIR"
}

run_as_valpo_shell() {
  runuser -u "$VALPO_USER" -- env \
    HOME="$STATE_DIR" \
    USER="$VALPO_USER" \
    PATH="${STATE_DIR}/.local/bin:${PATH}" \
    MISE_RUBY_COMPILE=false \
    MISE_YES=1 \
    bash -lc "$1"
}

install_mise() {
  [[ "$SKIP_DEPS" -eq 0 ]] || return 0
  if [[ -x "$MISE_BIN" ]]; then
    log "mise already installed at ${MISE_BIN}"
    return 0
  fi

  log "Installing mise for ${VALPO_USER}"
  run_as_valpo_shell "curl -fsSL https://mise.run | sh"
  [[ -x "$MISE_BIN" ]] || fail "mise was not installed at ${MISE_BIN}"
}

install_ruby() {
  [[ "$SKIP_DEPS" -eq 0 ]] || return 0
  [[ -x "$MISE_BIN" ]] || fail "mise is required at ${MISE_BIN}"

  log "Configuring mise to use precompiled Ruby binaries"
  run_as_valpo_shell "'${MISE_BIN}' settings set ruby.compile false"

  log "Installing Ruby ${RUBY_VERSION} with mise precompiled binaries"
  install_log="$(mktemp)"
  if ! run_as_valpo_shell "'${MISE_BIN}' install ruby@${RUBY_VERSION}" 2>&1 | tee "$install_log"; then
    rm -f "$install_log"
    fail "Ruby ${RUBY_VERSION} installation failed"
  fi

  if grep -Eiq 'ruby-build|building ruby|compiling ruby|installing ruby from source' "$install_log"; then
    rm -f "$install_log"
    fail "mise attempted to compile Ruby from source; precompiled Ruby is required"
  fi
  rm -f "$install_log"

  run_as_valpo_shell "'${MISE_BIN}' x ruby@${RUBY_VERSION} -- ruby -v"
}

copy_source() {
  command -v rsync >/dev/null 2>&1 || fail "rsync is required to copy source"
  log "Copying source from ${SOURCE_DIR} to ${PREFIX}"
  if [[ "$(realpath "$SOURCE_DIR")" == "$(realpath -m "$PREFIX")" ]]; then
    log "Source and prefix are the same; skipping source copy"
    return 0
  fi

  rsync -a --delete \
    --exclude '.git' \
    --exclude '.bundle' \
    --exclude 'tmp' \
    --exclude 'vendor/bundle' \
    --exclude 'test' \
    "${SOURCE_DIR}/" "${PREFIX}/"
  chown -R root:root "$PREFIX"
}

write_valpo_config() {
  log "Writing ${CONFIG_PATH}"
  tmp="$(mktemp)"
  cat > "$tmp" <<CONFIG
# Generated by Valpo installer.
production:
  database_path: ${STATE_DIR}/valpo.db
  api_host: 127.0.0.1
  api_port: 7092
  caddy_config_path: ${CADDY_GENERATED_PATH}
  caddy_reload_config_path: ${CADDY_RELOAD_CONFIG_PATH}
  docker_network: valpo
  worker_poll_interval: 2
  app_port_start: 20000
  app_port_end: 29999
  healthcheck_timeout: 30
  deploy_drain_delay: 2
CONFIG

  if [[ -f "$CONFIG_PATH" ]] && ! cmp -s "$tmp" "$CONFIG_PATH"; then
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$tmp" "$CONFIG_PATH"
  rm -f "$tmp"
}

ensure_generated_caddy_file() {
  log "Ensuring ${CADDY_GENERATED_PATH}"
  if [[ ! -f "$CADDY_GENERATED_PATH" ]]; then
    printf '# Generated by Valpo. Do not edit by hand.\n' > "$CADDY_GENERATED_PATH"
  fi
  chown "$VALPO_USER:$VALPO_GROUP" "$CADDY_GENERATED_PATH"
  chmod 0644 "$CADDY_GENERATED_PATH"
}

ensure_caddy_import() {
  log "Ensuring Caddy imports Valpo routes"
  local start_marker="# BEGIN VALPO"
  local end_marker="# END VALPO"
  local import_line="import ${CADDY_GENERATED_PATH}"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "$CADDY_RELOAD_CONFIG_PATH" ]]; then
    printf '%s\n%s\n%s\n' "$start_marker" "$import_line" "$end_marker" > "$tmp"
  elif grep -Fxq "$start_marker" "$CADDY_RELOAD_CONFIG_PATH"; then
    awk -v start="$start_marker" -v end="$end_marker" -v import_line="$import_line" '
      $0 == start {
        print start
        print import_line
        in_block = 1
        next
      }
      $0 == end {
        print end
        in_block = 0
        next
      }
      !in_block { print }
    ' "$CADDY_RELOAD_CONFIG_PATH" > "$tmp"
  else
    cp "$CADDY_RELOAD_CONFIG_PATH" "$tmp"
    printf '\n%s\n%s\n%s\n' "$start_marker" "$import_line" "$end_marker" >> "$tmp"
  fi

  install -m 0644 "$tmp" "$CADDY_RELOAD_CONFIG_PATH"
  rm -f "$tmp"
}

install_systemd_units() {
  log "Installing systemd units"
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-api.service" /etc/systemd/system/valpo-api.service
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-worker.service" /etc/systemd/system/valpo-worker.service
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-migrate.service" /etc/systemd/system/valpo-migrate.service
}

locked_bundler_version() {
  awk '
    /^BUNDLED WITH$/ {
      getline
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "${PREFIX}/Gemfile.lock"
}

install_gems() {
  [[ "$SKIP_DEPS" -eq 0 ]] || return 0
  bundler_version="$(locked_bundler_version)"
  [[ -n "$bundler_version" ]] || fail "Gemfile.lock must include BUNDLED WITH"

  log "Installing Ruby gems"
  run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- gem install bundler -v '${bundler_version}'"
  run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ config set --global path '${STATE_DIR}/bundle'"
  run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ config set --global frozen true"
  run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ install --jobs 4 --retry 3"
}

run_migrations() {
  log "Running database migrations"
  run_as_valpo_shell "cd '${PREFIX}' && VALPO_ENV=production VALPO_CONFIG='${CONFIG_PATH}' '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle exec rake db:migrate"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

start_services() {
  [[ "$NO_START" -eq 0 ]] || return 0
  systemd_available || fail "systemd is not running; rerun with --no-start in container/test environments"

  log "Enabling and starting services"
  systemctl daemon-reload
  systemctl enable --now docker.service
  systemctl enable --now caddy.service
  systemctl restart caddy.service
  systemctl enable valpo-api.service valpo-worker.service
  systemctl restart valpo-api.service valpo-worker.service
}

main() {
  require_root
  require_ubuntu
  install_packages
  ensure_user_and_dirs
  install_mise
  install_ruby
  copy_source
  write_valpo_config
  ensure_generated_caddy_file
  ensure_caddy_import
  install_systemd_units
  install_gems
  run_migrations
  start_services
  log "Valpo installation complete"
}

main
