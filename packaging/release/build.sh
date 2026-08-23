#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR=""
ARCHITECTURE=""
EXPECTED_TAG=""

usage() {
  cat <<'USAGE'
Usage: packaging/release/build.sh --architecture ARCH --output-dir DIR [--expected-tag TAG]

Build an immutable Valpo Linux artifact for the native Docker architecture.
Supported architectures: amd64, arm64.
USAGE
}

fail() {
  printf 'valpo-release: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture)
      [[ $# -ge 2 ]] || fail "--architecture requires a value"
      ARCHITECTURE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --expected-tag)
      [[ $# -ge 2 ]] || fail "--expected-tag requires a value"
      EXPECTED_TAG="$2"
      shift 2
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

case "$ARCHITECTURE" in
  amd64|arm64) ;;
  "") fail "--architecture is required" ;;
  *) fail "Unsupported architecture: ${ARCHITECTURE}" ;;
esac
[[ -n "$OUTPUT_DIR" ]] || fail "--output-dir is required"
command -v docker >/dev/null 2>&1 || fail "docker is required"

version="$(ruby -rjson -e 'print JSON.parse(File.binread(ARGV.fetch(0))).fetch("version")' "${SOURCE_DIR}/release.json")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] ||
  fail "release.json version is not safe semantic version text: ${version}"
if [[ -n "$EXPECTED_TAG" && "$EXPECTED_TAG" != "v${version}" ]]; then
  fail "Release tag ${EXPECTED_TAG} does not match v${version}"
fi

code_version="$(ruby -I"${SOURCE_DIR}/lib" -rvalpo/version -e 'print Valpo::VERSION')"
[[ "$code_version" == "$version" ]] || fail "release.json version ${version} does not match Valpo::VERSION ${code_version}"

runtime_ruby_version="$(ruby -e '
  match = File.binread(ARGV.fetch(0)).match(/^ruby = "([^"]+)"$/)
  abort "missing [tools] Ruby version" unless match
  print match[1]
' "${SOURCE_DIR}/.mise.toml")"
grep -F "  ruby ${runtime_ruby_version}" "${SOURCE_DIR}/Gemfile.lock" >/dev/null ||
  fail ".mise.toml Ruby ${runtime_ruby_version} does not match Gemfile.lock"

docker_architecture="$(docker info --format '{{.Architecture}}')"
case "$docker_architecture" in
  x86_64) docker_architecture=amd64 ;;
  aarch64) docker_architecture=arm64 ;;
esac
[[ "$docker_architecture" == "$ARCHITECTURE" ]] ||
  fail "Native Docker architecture is ${docker_architecture}; refusing a ${ARCHITECTURE} emulated build"

source_date_epoch="${SOURCE_DATE_EPOCH:-}"
if [[ -z "$source_date_epoch" ]]; then
  source_date_epoch="$(git -C "$SOURCE_DIR" log -1 --format=%ct)"
fi
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || fail "SOURCE_DATE_EPOCH must be an integer"

bundler_version="$(awk '
  /^BUNDLED WITH$/ {
    getline
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
    print
    exit
  }
' "${SOURCE_DIR}/Gemfile.lock")"
[[ -n "$bundler_version" ]] || fail "Gemfile.lock must include BUNDLED WITH"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

build_args=(
  buildx build
  --file "${SCRIPT_DIR}/Dockerfile"
  --platform "linux/${ARCHITECTURE}"
  --target artifact
  --build-arg "VALPO_VERSION=${version}"
  --build-arg "RUBY_VERSION=${runtime_ruby_version}"
  --build-arg "BUNDLER_VERSION=${bundler_version}"
  --build-arg "SOURCE_DATE_EPOCH=${source_date_epoch}"
  --output "type=local,dest=${OUTPUT_DIR}"
)
if [[ -n "${VALPO_BUILDX_CACHE_FROM:-}" ]]; then
  build_args+=(--cache-from "$VALPO_BUILDX_CACHE_FROM")
fi
if [[ -n "${VALPO_BUILDX_CACHE_TO:-}" ]]; then
  build_args+=(--cache-to "$VALPO_BUILDX_CACHE_TO")
fi
build_args+=("${SOURCE_DIR}")

docker "${build_args[@]}"
test -f "${OUTPUT_DIR}/valpo-${version}-linux-${ARCHITECTURE}.tar.zst" ||
  fail "Builder did not produce the expected archive"
