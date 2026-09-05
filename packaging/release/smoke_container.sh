#!/usr/bin/env bash
set -euo pipefail

version="${1:?version is required}"
architecture="${2:?architecture is required}"
release_root="/opt/valpo/releases/${version}"
ruby="${release_root}/runtime/ruby/bin/ruby"

test -x "$ruby"
test -x "${release_root}/tools/pack"
for launcher in valpo valpo-api valpo-maintenance valpo-migrate valpo-worker; do
  test -x "${release_root}/bin/${launcher}"
done
test -r "$release_root/release.json"
test -r "$release_root/db/migrations/001_bootstrap.rb"
test -r "$release_root/packaging/valpo.yml.example"
test ! -e "$release_root/docs"
test ! -e "$release_root/test"
test ! -e "$release_root/.git"
test ! -e "$release_root/runtime/ruby/include"
test ! -e "$release_root/runtime/ruby/share/ri"
test ! -e "$release_root/runtime/ruby/share/man"
test -z "$(find "$release_root/runtime/ruby" -type f -name '*.a' -print -quit)"
test -z "$(find "$release_root" -type f -name '*.gem' -print -quit)"
for gem_root in "$release_root/runtime/ruby/lib/ruby/gems" "$release_root/bundle"; do
  if find "$gem_root" -type d \( \
    -name cache -o -name doc -o -name docs -o -name test -o -name spec -o -name man -o -name include \
  \) -print -quit | grep -q .; then
    printf 'Pruned gem content leaked into the release: %s\n' "$gem_root" >&2
    exit 1
  fi
done

test "$($ruby -e 'print RUBY_VERSION')" = "4.0.5"
case "$architecture" in
  amd64)
    expected_platform=x86_64-linux
    expected_machine=x86_64
    ;;
  arm64)
    expected_platform=aarch64-linux
    expected_machine=aarch64
    ;;
  *)
    printf 'Unsupported smoke-test architecture: %s\n' "$architecture" >&2
    exit 1
    ;;
esac
test "$(uname -m)" = "$expected_machine"
"$ruby" -e 'abort "unexpected Ruby platform: #{RUBY_PLATFORM}" unless RUBY_PLATFORM.start_with?(ARGV.fetch(0))' "$expected_platform"
"${release_root}/tools/pack" version | grep -F '0.40.8' >/dev/null

if find "$release_root" \( -name mise -o -name 'mise-*' -o -name '.mise*' \) ! -name mise.lock -print -quit | grep -q .; then
  printf 'mise runtime files leaked into the release\n' >&2
  exit 1
fi
for development_gem in minitest rack-test standard rubocop rubocop-ast rubocop-performance; do
  if find "$release_root/bundle" -type d -path "*/gems/${development_gem}-*" -print -quit | grep -q .; then
    printf 'Development gem leaked into release: %s\n' "$development_gem" >&2
    exit 1
  fi
done

while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q 'ELF'; then
    if ldd "$candidate" 2>&1 | grep -q 'not found'; then
      printf 'Unresolved dynamic library in %s\n' "$candidate" >&2
      ldd "$candidate" >&2
      exit 1
    fi
  fi
done < <(find "$release_root" -type f \( -perm /111 -o -name '*.so' \) -print0)

export RUBYLIB="${release_root}/bundle"
export BUNDLE_GEMFILE="${release_root}/Gemfile"
# $LOADED_FEATURES is Ruby, not a shell expansion.
# shellcheck disable=SC2016
"$ruby" -I"${release_root}/lib" -rbundler/setup -rjson -rroda -rsequel -rvalpo -e '
  bad = $LOADED_FEATURES.grep(%r{/(source|workspace|home/runner/work)/})
  abort "Loaded files outside the release: #{bad.join(", ")}" unless bad.empty?
'

version_json="$("${release_root}/bin/valpo" version --json)"
"$ruby" -rjson -e 'abort "wrong version" unless JSON.parse(ARGV.fetch(0)).fetch("version") == ARGV.fetch(1)' "$version_json" "$version"

smoke_state=/tmp/valpo-release-smoke
install -d -m 0700 "$smoke_state/secrets"
export VALPO_ENV=production
export VALPO_DATABASE_PATH="$smoke_state/valpo.db"
export VALPO_ENCRYPTION_KEY_PATH="$smoke_state/secrets/master.key"
export VALPO_API_HOST=127.0.0.1
export VALPO_API_PORT=17092
export VALPO_CADDY_CONFIG_PATH="$smoke_state/valpo.caddy"
export VALPO_CADDY_RELOAD_CONFIG_PATH="$smoke_state/Caddyfile"
export VALPO_INSTALLATION_METADATA="$smoke_state/missing-installation.json"

schema_target="$("$ruby" -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("schema_target")' "$release_root/release.json")"
migration_output="$("${release_root}/bin/valpo-migrate")"
printf '%s\n' "$migration_output" | grep -F "schema ${schema_target}" >/dev/null

api_log="$smoke_state/api.log"
"${release_root}/bin/valpo-api" >"$api_log" 2>&1 &
api_pid=$!
cleanup() {
  kill "$api_pid" >/dev/null 2>&1 || true
  wait "$api_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

health_status=""
for _attempt in $(seq 1 50); do
  health_status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:17092/health" 2>/dev/null || true)"
  if [[ "$health_status" == 401 ]]; then
    break
  fi
  if ! kill -0 "$api_pid" >/dev/null 2>&1; then
    cat "$api_log" >&2
    exit 1
  fi
  sleep 0.1
done
[[ "$health_status" == 401 ]] || {
  cat "$api_log" >&2
  exit 1
}

bootstrap="$(curl --fail --silent --show-error \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"name":"release-smoke","scopes":["admin"]}' \
  "http://127.0.0.1:17092/v1/api-credentials")"
api_token="$("$ruby" -rjson -e 'print JSON.parse(ARGV.fetch(0)).fetch("token")' "$bootstrap")"
health="$(curl --fail --silent --show-error \
  --header "Authorization: Bearer ${api_token}" \
  "http://127.0.0.1:17092/health")"
"$ruby" -rjson -e '
  payload = JSON.parse(ARGV.fetch(0))
  abort "unhealthy API" unless payload.fetch("ok")
  abort "wrong version" unless payload.fetch("version") == ARGV.fetch(1)
  abort "wrong schema" unless payload.fetch("schema_version") == payload.fetch("schema_target")
' "$health" "$version"

cleanup
trap - EXIT
