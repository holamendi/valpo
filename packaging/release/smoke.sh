#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARCHIVE=""
ARCHITECTURE=""

usage() {
  cat <<'USAGE'
Usage: packaging/release/smoke.sh --architecture ARCH --archive PATH

Smoke-test a Valpo release artifact on the native Docker architecture.
USAGE
}

fail() {
  printf 'valpo-release-smoke: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture)
      [[ $# -ge 2 ]] || fail "--architecture requires a value"
      ARCHITECTURE="$2"
      shift 2
      ;;
    --archive)
      [[ $# -ge 2 ]] || fail "--archive requires a value"
      ARCHIVE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done

case "$ARCHITECTURE" in
  amd64|arm64) ;;
  "") fail "--architecture is required" ;;
  *) fail "Unsupported architecture: ${ARCHITECTURE}" ;;
esac
[[ -f "$ARCHIVE" ]] || fail "Artifact does not exist: ${ARCHIVE}"
command -v docker >/dev/null 2>&1 || fail "docker is required"

version="$(ruby -rjson -e 'print JSON.parse(File.binread(ARGV.fetch(0))).fetch("version")' "${SOURCE_DIR}/release.json")"
expected_name="valpo-${version}-linux-${ARCHITECTURE}.tar.zst"
[[ "$(basename "$ARCHIVE")" == "$expected_name" ]] ||
  fail "Artifact must be named ${expected_name}"

docker_architecture="$(docker info --format '{{.Architecture}}')"
case "$docker_architecture" in
  x86_64) docker_architecture=amd64 ;;
  aarch64) docker_architecture=arm64 ;;
esac
[[ "$docker_architecture" == "$ARCHITECTURE" ]] ||
  fail "Native Docker architecture is ${docker_architecture}; refusing an emulated smoke test"

context="$(mktemp -d)"
image="valpo/release-smoke:${version}-${ARCHITECTURE}-$$"
cleanup() {
  docker image rm --force "$image" >/dev/null 2>&1 || true
  rm -rf "$context"
}
trap cleanup EXIT

install -d "$context/packaging/release"
install -m 0644 "$ARCHIVE" "$context/$expected_name"
install -m 0644 "${SCRIPT_DIR}/runtime-packages.txt" "$context/packaging/release/runtime-packages.txt"
install -m 0755 "${SCRIPT_DIR}/smoke_container.sh" "$context/packaging/release/smoke_container.sh"

docker buildx build \
  --file "${SCRIPT_DIR}/Smoke.Dockerfile" \
  --platform "linux/${ARCHITECTURE}" \
  --build-arg "ARCHIVE=${expected_name}" \
  --build-arg "ARCHITECTURE=${ARCHITECTURE}" \
  --build-arg "VALPO_VERSION=${version}" \
  --tag "$image" \
  --load \
  "$context"
