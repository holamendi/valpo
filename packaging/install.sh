#!/usr/bin/env bash
set -euo pipefail
umask 077

RUBY_VERSION="4.0.5"
PACK_VERSION="0.40.8"
PACK_AMD64_SHA256="3b8cfd4287ea6c648ccff9c17cbfa61ae615839071a5de804f3b84316ed99a93"
PACK_ARM64_SHA256="51b1b8ba93f3cff0e25fdc4c099daddd962ea2c691ccd13bd607f0a452c42039"
VALPO_USER="valpo"
VALPO_GROUP="valpo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="/opt/valpo"
CONFIG_PATH="/etc/valpo/valpo.yml"
STATE_DIR="/var/lib/valpo"
LOG_DIR="/var/log/valpo"
CLI_PATH="/usr/local/bin/valpo"
PACK_PATH="${STATE_DIR}/.local/bin/pack"
REDIS_SYSCTL_PATH="/etc/sysctl.d/99-valpo-redis.conf"
SKIP_DEPS="${VALPO_INSTALL_SKIP_DEPS:-0}"
NO_START="${VALPO_INSTALL_NO_START:-0}"

usage() {
  cat <<USAGE
Usage: packaging/install.sh

Options:
  -h, --help  Show this help
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
  [[ "${EUID}" -eq 0 ]] || fail "This installer must run as root"
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] ||
    fail "This installer supports Ubuntu 26.04 LTS only"
}

bootstrap_schema_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

preflight_bootstrap_schema() {
  local incoming_schema="${SOURCE_DIR}/db/migrations/001_bootstrap.rb"
  local installed_schema="${PREFIX}/db/migrations/001_bootstrap.rb"

  [[ -f "$incoming_schema" ]] || fail "Incoming source is missing db/migrations/001_bootstrap.rb"
  [[ -f "${SOURCE_DIR}/release.json" ]] || fail "Incoming source is missing release.json"
  if [[ ! -f "$installed_schema" ]]; then
    [[ ! -e "$PREFIX" && ! -e "${STATE_DIR}/valpo.db" && ! -e "$CONFIG_PATH" ]] ||
      fail "The installed Valpo layout is incomplete. Back up required configuration, database, and managed-volume data, run packaging/uninstall.sh, then reinstall from a checkout outside /opt/valpo."
    return 0
  fi
  [[ -f "${STATE_DIR}/valpo.db" && -f "$CONFIG_PATH" ]] ||
    fail "The installed Valpo layout is incomplete. Back up required configuration, database, and managed-volume data, run packaging/uninstall.sh, then reinstall from a checkout outside /opt/valpo."

  local incoming_sha
  local installed_sha
  incoming_sha="$(bootstrap_schema_sha256 "$incoming_schema")"
  installed_sha="$(bootstrap_schema_sha256 "$installed_schema")"
  [[ "$incoming_sha" == "$installed_sha" ]] ||
    fail "Bootstrap schema changed; pre-release in-place upgrade is unsafe. Back up required configuration, database, and managed-volume data, run packaging/uninstall.sh, then reinstall from a checkout outside /opt/valpo."
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
    docker-buildx \
    git \
    gnupg \
    lsb-release \
    procps \
    rsync \
    tar \
    unzip \
    xz-utils
}

check_download_connectivity() {
  local endpoint
  for endpoint in https://github.com https://registry-1.docker.io/v2/; do
    curl --silent --show-error --location --output /dev/null --connect-timeout 10 --max-time 30 "$endpoint" ||
      fail "Cannot reach ${endpoint}; check DNS, firewall, and IPv4/IPv6 routing before installing"
  done
  if ip -6 route show default | grep -q .; then
    curl -6 --silent --show-error --output /dev/null --connect-timeout 5 --max-time 10 https://registry-1.docker.io/v2/ 2>/dev/null ||
      fail "IPv6 has a default route but cannot reach Docker Hub. Repair upstream IPv6 or disable IPv6 advertisements on this host, then retry. Valpo will not change shared network configuration."
  fi
}

configure_redis_host() {
  command -v sysctl >/dev/null 2>&1 || fail "sysctl is required to configure the Redis host prerequisite"

  log "Configuring Redis host memory overcommit"
  local temporary
  temporary="$(mktemp)"
  printf 'vm.overcommit_memory = 1\n' > "$temporary"
  install -o root -g root -m 0644 "$temporary" "$REDIS_SYSCTL_PATH"
  rm -f "$temporary"

  sysctl -w vm.overcommit_memory=1 >/dev/null
  [[ "$(sysctl -n vm.overcommit_memory)" == "1" ]] ||
    fail "Could not activate vm.overcommit_memory=1 for Redis"
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
  install -d -m 0755 "$CONFIG_DIR" /etc/caddy /etc/systemd/system /usr/local/bin
  install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0755 "$STATE_DIR" "${STATE_DIR}/caddy"
  install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0750 "${STATE_DIR}/bundle" "$LOG_DIR"
  install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0700 "${STATE_DIR}/secrets"
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

install_pack() {
  [[ "$SKIP_DEPS" -eq 0 ]] || return 0

  local architecture
  local asset
  local checksum
  architecture="$(dpkg --print-architecture)"
  case "$architecture" in
    amd64)
      asset="pack-v${PACK_VERSION}-linux.tgz"
      checksum="$PACK_AMD64_SHA256"
      ;;
    arm64)
      asset="pack-v${PACK_VERSION}-linux-arm64.tgz"
      checksum="$PACK_ARM64_SHA256"
      ;;
    *)
      log "Skipping pack installation on unsupported architecture ${architecture}; Dockerfile builds remain available"
      return 0
      ;;
  esac

  local temporary
  temporary="$(mktemp -d)"
  log "Installing pack ${PACK_VERSION} for ${architecture}"
  curl -fsSL "https://github.com/buildpacks/pack/releases/download/v${PACK_VERSION}/${asset}" -o "${temporary}/${asset}"
  printf '%s  %s\n' "$checksum" "${temporary}/${asset}" | sha256sum --check --status ||
    fail "pack ${PACK_VERSION} checksum verification failed"
  tar -xzf "${temporary}/${asset}" -C "$temporary" pack
  install -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0755 "${temporary}/pack" "$PACK_PATH"
  rm -rf "$temporary"
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
  chmod 0755 "$PREFIX"
}

write_valpo_config() {
  if [[ -e "$CONFIG_PATH" ]]; then
    log "Preserving existing ${CONFIG_PATH}"
  else
    log "Installing ${CONFIG_PATH}"
    install -o root -g "$VALPO_GROUP" -m 0640 "${PREFIX}/packaging/valpo.yml.example" "$CONFIG_PATH"
  fi
  chown root:"$VALPO_GROUP" "$CONFIG_PATH"
  chmod 0640 "$CONFIG_PATH"
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
  local formatted
  local tmp
  formatted="$(mktemp)"
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

  awk -v start="$start_marker" '
    /^[[:space:]]*$/ {
      pending_blanks = pending_blanks $0 ORS
      next
    }
    $0 == start {
      if (saw_content) {
        print ""
        print ""
      }
      pending_blanks = ""
      print
      saw_content = 1
      next
    }
    {
      printf "%s", pending_blanks
      pending_blanks = ""
      print
      saw_content = 1
    }
    END {
      printf "%s", pending_blanks
    }
  ' "$tmp" > "$formatted"
  mv "$formatted" "$tmp"

  install -m 0644 "$tmp" "$CADDY_RELOAD_CONFIG_PATH"
  rm -f "$tmp" "$formatted"
}

install_systemd_units() {
  log "Installing systemd units"
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-api.service" /etc/systemd/system/valpo-api.service
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-worker.service" /etc/systemd/system/valpo-worker.service
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-migrate.service" /etc/systemd/system/valpo-migrate.service
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-maintenance.service" /etc/systemd/system/valpo-maintenance.service
  install -m 0644 "${PREFIX}/packaging/systemd/valpo-maintenance.timer" /etc/systemd/system/valpo-maintenance.timer
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
  bundler_version="$(locked_bundler_version)"
  [[ -n "$bundler_version" ]] || fail "Gemfile.lock must include BUNDLED WITH"

  if [[ "$SKIP_DEPS" -eq 0 ]]; then
    log "Installing Ruby gems"
    run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- gem install bundler -v '${bundler_version}'"
    run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ config set --global path '${STATE_DIR}/bundle'"
    run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ config set --global frozen true"
    run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ install --standalone=default --jobs 4 --retry 3"
  else
    log "Refreshing standalone Ruby setup"
    run_as_valpo_shell "cd '${PREFIX}' && '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle _${bundler_version}_ install --local --standalone=default --jobs 4"
  fi

  [[ -r "${STATE_DIR}/bundle/bundler/setup.rb" ]] ||
    fail "Bundler did not create ${STATE_DIR}/bundle/bundler/setup.rb"
}

install_cli_wrapper() {
  log "Installing ${CLI_PATH}"
  tmp="$(mktemp)"
  cat > "$tmp" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

VALPO_USER="${VALPO_USER}"
STATE_DIR="${STATE_DIR}"
PREFIX="${PREFIX}"
CONFIG_PATH="${CONFIG_PATH}"
RUBY_VERSION="${RUBY_VERSION}"
MISE_BIN="${MISE_BIN}"

if [[ "\$(id -un)" != "\${VALPO_USER}" ]]; then
  if [[ "\${EUID}" -ne 0 ]]; then
    printf 'valpo must run as %s or root\n' "\${VALPO_USER}" >&2
    exit 1
  fi
  exec runuser -u "\${VALPO_USER}" -- "\$0" "\$@"
fi

export HOME="\${STATE_DIR}"
export USER="\${VALPO_USER}"
export PATH="\${STATE_DIR}/.local/bin:\${PATH}"
export MISE_RUBY_COMPILE=false
export MISE_YES=1
export VALPO_ENV="\${VALPO_ENV:-production}"
export VALPO_CONFIG="\${VALPO_CONFIG:-\${CONFIG_PATH}}"

cd "\${PREFIX}"
exec "\${MISE_BIN}" x ruby@"\${RUBY_VERSION}" -- bundle exec exe/valpo "\$@"
SCRIPT

  install -m 0755 "$tmp" "$CLI_PATH"
  rm -f "$tmp"
}

run_migrations() {
  log "Running database migrations"
  run_as_valpo_shell "cd '${PREFIX}' && VALPO_ENV=production VALPO_CONFIG='${CONFIG_PATH}' '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle exec rake db:migrate"
  chown "$VALPO_USER:$VALPO_GROUP" "${STATE_DIR}/valpo.db"
  chmod 0600 "${STATE_DIR}/valpo.db"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

bootstrap_api_credential() {
  log "Ensuring the initial API credential exists"
  local temporary
  temporary="$(mktemp "${CONFIG_DIR}/.bootstrap-token.XXXXXX")"
  if ! run_as_valpo_shell "cd '${PREFIX}' && VALPO_ENV=production VALPO_CONFIG='${CONFIG_PATH}' '${MISE_BIN}' x ruby@${RUBY_VERSION} -- bundle exec ruby exe/valpo-bootstrap" > "$temporary"; then
    rm -f "$temporary"
    fail "Initial API credential setup failed"
  fi
  if [[ -s "$temporary" ]]; then
    if [[ -e "${CONFIG_DIR}/bootstrap-token" ]]; then
      fail "An existing bootstrap-token file was preserved. The new credential is saved privately at ${temporary}; inspect both before continuing."
    fi
    mv "$temporary" "${CONFIG_DIR}/bootstrap-token"
    chmod 0600 "${CONFIG_DIR}/bootstrap-token"
    log "Initial admin token saved at ${CONFIG_DIR}/bootstrap-token (root-only); it is not printed in installation logs"
    log "After startup, run: valpo login --server http://127.0.0.1:7092 --name local --with-token < ${CONFIG_DIR}/bootstrap-token"
  else
    rm -f "$temporary"
    log "API bootstrap already completed; existing credentials are unchanged"
  fi
}

start_services() {
  [[ "$NO_START" -eq 0 ]] || return 0
  systemd_available || fail "systemd is not running"

  log "Enabling and starting services"
  systemctl daemon-reload
  systemctl enable --now docker.service
  if docker network inspect valpo >/dev/null 2>&1; then
    [[ "$(docker network inspect --format '{{ index .Labels "valpo.owned" }}' valpo)" == "true" ]] ||
      fail "Docker network valpo already exists without valpo.owned=true; inspect and remove that network before installing"
  else
    docker network create --label valpo.owned=true valpo >/dev/null
  fi
  systemctl enable --now caddy.service
  systemctl restart caddy.service
  systemctl enable valpo-api.service valpo-worker.service
  systemctl enable --now valpo-maintenance.timer
  systemctl restart valpo-api.service valpo-worker.service
}

main() {
  require_root
  require_ubuntu
  preflight_bootstrap_schema
  install_packages
  check_download_connectivity
  configure_redis_host
  ensure_user_and_dirs
  install_mise
  install_ruby
  install_pack
  docker buildx version >/dev/null || fail "Docker Buildx is required; install docker-buildx"
  copy_source
  write_valpo_config
  ensure_generated_caddy_file
  ensure_caddy_import
  install_systemd_units
  install_gems
  install_cli_wrapper
  run_migrations
  bootstrap_api_credential
  start_services
  log "Valpo installation complete"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
