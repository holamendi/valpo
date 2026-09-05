#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: packaging/vps-source-smoke-test.sh USER@HOST DOMAIN_SUFFIX [options]

Installs the current checkout and tests a manifest-free GitHub source deployment
in a unique project. The test omits ref, build strategy, Dockerfile, context,
and port so it exercises remote HEAD and automatic source-build defaults.

GitHub App or PAT authentication must already be configured. Its encrypted
database record and public authentication status are checked before and after
the test; the script never logs out of GitHub or removes the credential.

Options:
  --repository OWNER/REPO  Repository to deploy. Default: holamendi/smol-roda.
  --source PATH            Source checkout to copy. Default: repository root.
  --remote-source PATH     Remote source path. Default: /tmp/valpo-source-src.
  --full-install           Install system dependencies as well as Valpo.
  --skip-install           Test the already-installed Valpo version.
  --project NAME           Test project. Default: valpo-source-<UTC timestamp>.
  -h, --help               Show this help.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 64
fi

ssh_target="$1"
domain_suffix="$2"
shift 2

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root"
remote_source="/tmp/valpo-source-src"
repository="holamendi/smol-roda"
install_mode="skip-deps"
project="valpo-source-$(date -u +%Y%m%d%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="$2"
      shift 2
      ;;
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
    --skip-install)
      install_mode="none"
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

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Repository must use OWNER/REPO syntax" >&2
  exit 64
fi
if [[ ! "$project" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Project must start with a lowercase letter and contain lowercase letters, digits, or hyphens" >&2
  exit 64
fi

domain="${project}.${domain_suffix}"
service="web"
service_id=""
project_id=""
credential_digest_before=""
cleanup_started=0

remote() {
  # Smoke-test commands are intentionally assembled on the client.
  # shellcheck disable=SC2029
  ssh "$ssh_target" "$1"
}

wait_for_https() {
  local url="$1"
  local attempts="${2:-60}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsSL "$url" >/dev/null; then
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

assert_github_auth() {
  remote "valpo auth status github --json" | grep -q '"authenticated":true'
}

credential_digest() {
  remote "cd /opt/valpo && runuser -u valpo -- env HOME=/var/lib/valpo USER=valpo PATH=/var/lib/valpo/.local/share/mise/installs/ruby/4.0.5/bin:/usr/bin:/bin VALPO_ENV=production bundle exec ruby -e 'require \"digest\"; require \"sqlite3\"; row = SQLite3::Database.new(\"/var/lib/valpo/valpo.db\").get_first_row(\"SELECT provider, kind, encrypted_payload, public_metadata_json FROM provider_credentials WHERE provider = ? ORDER BY kind LIMIT 1\", \"github\"); abort \"GitHub credential is missing\" unless row; puts Digest::SHA256.hexdigest(row.join(\"\\0\"))'"
}

cleanup() {
  local exit_code=$?
  local cleanup_failed=0
  trap - EXIT

  if [[ "$cleanup_started" -eq 1 ]]; then
    exit "$exit_code"
  fi
  cleanup_started=1

  echo "[source-smoke] cleaning up ${project}"
  if remote "valpo service show '${service}' --project '${project}' >/dev/null 2>&1"; then
    remote "valpo service delete '${service}' --project '${project}' --force --timeout 180" || cleanup_failed=1
  fi
  if remote "valpo project show '${project}' >/dev/null 2>&1"; then
    remote "valpo project delete '${project}' --timeout 180" || cleanup_failed=1
  fi
  if [[ -n "$project_id" ]] && remote "docker ps -a --filter 'label=valpo.project_id=${project_id}' --format '{{.Names}}' | grep ."; then
    echo "[source-smoke] containers remain for ${project_id}" >&2
    cleanup_failed=1
  fi
  if remote "grep -F '${domain}' /var/lib/valpo/caddy/valpo.caddy"; then
    echo "[source-smoke] route remains for ${domain}" >&2
    cleanup_failed=1
  fi
  if ! assert_github_auth; then
    echo "[source-smoke] GitHub authentication is no longer configured" >&2
    cleanup_failed=1
  elif [[ "$(credential_digest)" != "$credential_digest_before" ]]; then
    echo "[source-smoke] GitHub credential changed during the test" >&2
    cleanup_failed=1
  fi

  if [[ "$cleanup_failed" -ne 0 ]]; then
    exit 1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

echo "[source-smoke] target=${ssh_target}"
echo "[source-smoke] project=${project}"
echo "[source-smoke] repository=${repository}"
echo "[source-smoke] domain=${domain}"

assert_github_auth
credential_digest_before="$(credential_digest)"

if [[ "$install_mode" != "none" ]]; then
  echo "[source-smoke] copying and installing current checkout"
  rsync -az --delete \
    --exclude .git \
    --exclude vendor/bundle \
    --exclude tmp \
    "${source_dir}/" "${ssh_target}:${remote_source}/"
  if [[ "$install_mode" == "skip-deps" ]]; then
    remote "VALPO_INSTALL_SKIP_DEPS=1 '${remote_source}/packaging/install.sh'"
  else
    remote "'${remote_source}/packaging/install.sh'"
  fi
fi

remote "systemctl is-active docker caddy valpo-api valpo-worker valpo-maintenance.timer"
remote "valpo system status --json"
assert_github_auth

remote "valpo domain set-default '${domain_suffix}' --timeout 180"

echo "[source-smoke] creating manifest-free source service"
remote "valpo project create '${project}'"
project_json="$(remote "valpo project show '${project}' --json")"
project_id="$(printf '%s\n' "$project_json" | id_from_json)"
test -n "$project_id"

remote "valpo service create '${service}' --project '${project}' --type web --source 'github:${repository}' --deploy --timeout 600"
service_json="$(remote "valpo service show '${service}' --project '${project}' --json")"
printf '%s\n' "$service_json"
service_id="$(printf '%s\n' "$service_json" | id_from_json)"
test -n "$service_id"
printf '%s\n' "$service_json" | grep -q '"repository": "'"$repository"'"'
printf '%s\n' "$service_json" | grep -q '"ref": "HEAD"'
printf '%s\n' "$service_json" | grep -q '"strategy": "auto"'
printf '%s\n' "$service_json" | grep -q '"dockerfile": null'
printf '%s\n' "$service_json" | grep -q '"context": "."'
printf '%s\n' "$service_json" | grep -q '"port_mode": "automatic"'
printf '%s\n' "$service_json" | grep -q '"resolved_internal_port": 3000'

release_json="$(remote "valpo release list '${service}' --project '${project}' --json")"
printf '%s\n' "$release_json"
printf '%s\n' "$release_json" | grep -q '"status": "active"'
printf '%s\n' "$release_json" | grep -Eq '"source_ref": "[0-9a-f]{40}"'
printf '%s\n' "$release_json" | grep -q '"strategy": "dockerfile"'
printf '%s\n' "$release_json" | grep -q '"internal_port": 3000'

echo "[source-smoke] adding and verifying HTTPS domain"
remote "valpo domain add '${service}' '${domain}' --project '${project}' --timeout 180"
wait_for_https "https://${domain}/"

echo "[source-smoke] verifying runtime metadata"
remote "container=\$(docker ps --filter 'label=valpo.service_id=${service_id}' --format '{{.Names}}' | head -n 1); test -n \"\$container\"; docker inspect \"\$container\" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -q '^PORT=3000$'"
assert_github_auth

echo "[source-smoke] ok"
