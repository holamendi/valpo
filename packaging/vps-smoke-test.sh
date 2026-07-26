#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: packaging/vps-smoke-test.sh USER@HOST DOMAIN_SUFFIX [options]

Runs a repeatable Valpo VPS smoke test over SSH:
  install/update Valpo from the current checkout
  apply a unique multi-service valpo.toml project
  deploy nginx:alpine to its web service
  provision and bind Postgres and Redis dependencies
  verify the automatically assigned HTTPS domain under DOMAIN_SUFFIX
  verify releases and logs
  optionally reboot and verify recovery
  delete every service
  delete the project and verify cleanup

Options:
  --source PATH          Source checkout to copy. Default: repository root.
  --remote-source PATH   Remote source path. Default: /tmp/valpo-src
  --full-install         Run the installer with dependencies (default).
  --skip-deps            Reuse dependencies already installed on the host.
  --reboot               Reboot the VPS and verify the app returns.
  --project NAME         Use a specific project name. Default: valpo-smoke-<UTC timestamp>.
  -h, --help             Show this help.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 64
fi

ssh_target="$1"
domain_suffix="$2"
shift 2

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root"
remote_source="/tmp/valpo-src"
install_mode="full"
reboot=0
project="valpo-smoke-$(date -u +%Y%m%d%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      source_dir="$2"
      shift 2
      ;;
    --remote-source)
      remote_source="$2"
      shift 2
      ;;
    --full-install)
      install_mode="full"
      shift
      ;;
    --skip-deps)
      install_mode="skip-deps"
      shift
      ;;
    --reboot)
      reboot=1
      shift
      ;;
    --project)
      project="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

domain="web.${project}.${domain_suffix}"
web_service="web"
postgres_service="database"
redis_service="cache"
project_id=""
postgres_service_id=""
redis_service_id=""
web_service_id=""
cleanup_started=0

remote() {
  # Smoke-test commands are intentionally assembled on the client.
  # shellcheck disable=SC2029
  ssh "$ssh_target" "$1"
}

wait_for_ssh() {
  local attempts="${1:-90}"
  local delay="${2:-5}"

  for _ in $(seq 1 "$attempts"); do
    if ssh -o ConnectTimeout=5 "$ssh_target" 'true' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  echo "Timed out waiting for SSH on ${ssh_target}" >&2
  return 1
}

wait_for_ssh_down() {
  local attempts="${1:-30}"
  local delay="${2:-2}"

  for _ in $(seq 1 "$attempts"); do
    if ! ssh -o ConnectTimeout=5 "$ssh_target" 'true' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  echo "Timed out waiting for SSH on ${ssh_target} to go down" >&2
  return 1
}

wait_for_services() {
  local attempts="${1:-90}"
  local delay="${2:-5}"

  for _ in $(seq 1 "$attempts"); do
    if ssh -o ConnectTimeout=5 "$ssh_target" 'systemctl is-active docker caddy valpo-api valpo-worker' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  echo "Timed out waiting for Valpo services on ${ssh_target}" >&2
  return 1
}

wait_for_https() {
  local url="$1"
  local attempts="${2:-60}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsSL "$url" | grep -i nginx >/dev/null; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for ${url}" >&2
  return 1
}

id_from_json() {
  sed -n 's/.*"id": "\([^"]*\)".*/\1/p' | head -n 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ "$cleanup_started" -eq 1 ]]; then
    exit "$exit_code"
  fi
  cleanup_started=1

  echo "[smoke] cleaning up ${project}"
  wait_for_services || true

  if remote "valpo service show '${postgres_service}' --project '${project}' >/dev/null 2>&1"; then
    remote "valpo service delete '${postgres_service}' --project '${project}' --force --timeout 180" || true
  fi
  if remote "valpo service show '${redis_service}' --project '${project}' >/dev/null 2>&1"; then
    remote "valpo service delete '${redis_service}' --project '${project}' --force --timeout 180" || true
  fi
  if remote "valpo service show '${web_service}' --project '${project}' >/dev/null 2>&1"; then
    remote "valpo service delete '${web_service}' --project '${project}' --force --timeout 180" || true
  fi

  if remote "valpo project show '${project}' >/dev/null 2>&1"; then
    remote "valpo project delete '${project}' --timeout 180" || true
  fi

  if [[ -n "$project_id" ]]; then
    if remote "docker ps -a --filter 'label=valpo.project_id=${project_id}' --format '{{.Names}}' | grep ."; then
      echo "[smoke] containers remain for ${project_id}" >&2
      exit 1
    fi
  fi
  if [[ -n "$postgres_service_id" ]]; then
    if remote "docker ps -a --filter 'label=valpo.service_id=${postgres_service_id}' --format '{{.Names}}' | grep ."; then
      echo "[smoke] containers remain for ${postgres_service_id}" >&2
      exit 1
    fi
  fi
  if [[ -n "$redis_service_id" ]]; then
    if remote "docker ps -a --filter 'label=valpo.service_id=${redis_service_id}' --format '{{.Names}}' | grep ."; then
      echo "[smoke] containers remain for ${redis_service_id}" >&2
      exit 1
    fi
  fi
  if [[ -n "$web_service_id" ]]; then
    if remote "docker ps -a --filter 'label=valpo.service_id=${web_service_id}' --format '{{.Names}}' | grep ."; then
      echo "[smoke] containers remain for ${web_service_id}" >&2
      exit 1
    fi
  fi

  if remote "grep -F '${domain}' /var/lib/valpo/caddy/valpo.caddy"; then
    echo "[smoke] route remains for ${domain}" >&2
    exit 1
  fi

  exit "$exit_code"
}
trap cleanup EXIT

echo "[smoke] target=${ssh_target}"
echo "[smoke] project=${project}"
echo "[smoke] domain=${domain}"

echo "[smoke] copying source"
rsync -az --delete \
  --exclude .git \
  --exclude vendor/bundle \
  --exclude tmp \
  "${source_dir}/" "${ssh_target}:${remote_source}/"

echo "[smoke] installing Valpo"
if [[ "$install_mode" == "skip-deps" ]]; then
  remote "VALPO_INSTALL_SKIP_DEPS=1 '${remote_source}/packaging/install.sh'"
else
  remote "'${remote_source}/packaging/install.sh'"
fi

echo "[smoke] verifying services"
remote "systemctl is-active docker caddy valpo-api valpo-worker"
remote "curl -fsS http://127.0.0.1:7092/health"

echo "[smoke] configuring app domain"
remote "valpo domain set-default '${domain_suffix}' --timeout 180"

echo "[smoke] applying project manifest"
remote "rm -f /tmp/valpo-smoke.toml; umask 077; printf '%s\n' \
  'schema = 1' \
  '[project]' \
  'name = \"${project}\"' \
  '[services.web]' \
  'type = \"web\"' \
  'port = 80' \
  'healthcheck = \"/\"' \
  'depends_on = [\"database\", \"cache\"]' \
  '[services.database]' \
  'type = \"postgres\"' \
  'version = \"18\"' \
  '[services.cache]' \
  'type = \"redis\"' \
  'version = \"8\"' > /tmp/valpo-smoke.toml; chown valpo:valpo /tmp/valpo-smoke.toml; chmod 0600 /tmp/valpo-smoke.toml"
remote "valpo project apply /tmp/valpo-smoke.toml --dry-run"
remote "valpo project apply /tmp/valpo-smoke.toml --timeout 600"
project_json="$(remote "valpo project show '${project}' --json")"
printf '%s\n' "$project_json"
project_id="$(printf '%s\n' "$project_json" | id_from_json)"
if [[ -z "$project_id" ]]; then
  echo "Could not parse project id" >&2
  exit 1
fi

echo "[smoke] deploying nginx"
remote "valpo service deploy '${web_service}' --project '${project}' --image nginx:alpine --timeout 300"

web_json="$(remote "valpo service show '${web_service}' --project '${project}' --json")"
postgres_json="$(remote "valpo service show '${postgres_service}' --project '${project}' --json")"
redis_json="$(remote "valpo service show '${redis_service}' --project '${project}' --json")"
web_service_id="$(printf '%s\n' "$web_json" | id_from_json)"
postgres_service_id="$(printf '%s\n' "$postgres_json" | id_from_json)"
redis_service_id="$(printf '%s\n' "$redis_json" | id_from_json)"
if [[ -z "$web_service_id" || -z "$postgres_service_id" || -z "$redis_service_id" ]]; then
  echo "Could not parse service ids" >&2
  exit 1
fi

echo "[smoke] verifying managed services"
remote "valpo service list --project '${project}'"
remote "valpo service show '${postgres_service}' --project '${project}'"
remote "valpo service show '${redis_service}' --project '${project}'"
remote "valpo service logs '${postgres_service}' --project '${project}' --tail 50"
remote "valpo service logs '${redis_service}' --project '${project}' --tail 50"
environment_output="$(remote "valpo service env '${web_service}' --project '${project}'")"
printf '%s\n' "$environment_output"
for secret_name in DATABASE_URL PGPASSWORD REDIS_URL REDIS_PASSWORD; do
  printf '%s\n' "$environment_output" | grep -F "$secret_name" | grep -F '********' >/dev/null
done
if printf '%s\n' "$environment_output" | grep -Eq 'postgres(ql)?://|redis://'; then
  echo "Managed credential value leaked into smoke-test output" >&2
  exit 1
fi
remote "redacted_output=\$(valpo service env '${web_service}' --project '${project}'); revealed_output=\$(valpo service env '${web_service}' --project '${project}' --reveal); for secret_name in DATABASE_URL PGPASSWORD REDIS_URL REDIS_PASSWORD; do secret_value=\$(printf '%s\n' \"\$revealed_output\" | awk -v name=\"\$secret_name\" '\$1 == name { print \$2; exit }'); test -n \"\$secret_value\"; if printf '%s\n' \"\$redacted_output\" | grep -F -- \"\$secret_value\" >/dev/null; then printf 'Credential value leaked for %s\n' \"\$secret_name\" >&2; exit 1; fi; done"
remote "container=\$(docker ps --filter 'label=valpo.service_id=${web_service_id}' --format '{{.Names}}' | head -n 1); test -n \"\$container\"; docker inspect \"\$container\" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'DATABASE_URL=|REDIS_URL=' >/dev/null"

echo "[smoke] verifying automatic domain"
remote "valpo domain list '${web_service}' --project '${project}' | grep -F '${domain}'"

echo "[smoke] verifying HTTPS"
wait_for_https "https://${domain}/"

echo "[smoke] checking releases and logs"
remote "valpo release list '${web_service}' --project '${project}'"
remote "valpo service logs '${web_service}' --project '${project}' --tail 50"
remote "valpo project logs '${project}' --tail 50"

if [[ "$reboot" -eq 1 ]]; then
  echo "[smoke] rebooting ${ssh_target}"
  remote "systemctl reboot" || true
  wait_for_ssh_down
  wait_for_ssh
  wait_for_services

  echo "[smoke] verifying post-reboot services and app"
  remote "systemctl is-active docker caddy valpo-api valpo-worker"
  remote "curl -fsS http://127.0.0.1:7092/health"
  wait_for_https "https://${domain}/"
  remote "valpo system repair --timeout 180"
  remote "valpo service list --project '${project}'"
  wait_for_https "https://${domain}/"
fi

echo "[smoke] verifying project delete is blocked while services remain"
if remote "valpo project delete '${project}' --timeout 180 >/tmp/valpo-bound-delete.out 2>&1"; then
  echo "[smoke] project delete succeeded while services were bound" >&2
  exit 1
fi

echo "[smoke] deleting services"
remote "valpo service delete '${postgres_service}' --project '${project}' --force --timeout 180"
remote "valpo service delete '${redis_service}' --project '${project}' --force --timeout 180"
remote "valpo service delete '${web_service}' --project '${project}' --force --timeout 180"

echo "[smoke] deleting project"
remote "valpo project delete '${project}' --timeout 180"

echo "[smoke] verifying cleanup"
if remote "valpo project show '${project}' >/dev/null 2>&1"; then
  echo "[smoke] project still exists after delete" >&2
  exit 1
fi
if remote "docker ps -a --filter 'label=valpo.project_id=${project_id}' --format '{{.Names}}' | grep ."; then
  echo "[smoke] containers still exist after delete" >&2
  exit 1
fi
if remote "docker ps -a --filter 'label=valpo.service_id=${postgres_service_id}' --format '{{.Names}}' | grep ."; then
  echo "[smoke] postgres service containers still exist after delete" >&2
  exit 1
fi
if remote "docker ps -a --filter 'label=valpo.service_id=${redis_service_id}' --format '{{.Names}}' | grep ."; then
  echo "[smoke] redis service containers still exist after delete" >&2
  exit 1
fi
if remote "grep -F '${domain}' /var/lib/valpo/caddy/valpo.caddy"; then
  echo "[smoke] route still exists after delete" >&2
  exit 1
fi

trap - EXIT
echo "[smoke] ok"
