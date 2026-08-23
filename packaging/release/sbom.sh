#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHITECTURE=""
ARCHIVE=""
OUTPUT=""
SYFT_VERSION="1.51.0"

usage() {
  cat <<'USAGE'
Usage: packaging/release/sbom.sh --architecture ARCH --archive PATH --output PATH

Generate an SPDX JSON SBOM for an extracted Valpo release artifact.
USAGE
}

fail() {
  printf 'valpo-release-sbom: %s\n' "$*" >&2
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
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a value"
      OUTPUT="$2"
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
  amd64)
    syft_asset="syft_${SYFT_VERSION}_linux_amd64.tar.gz"
    syft_sha256="2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f"
    ;;
  arm64)
    syft_asset="syft_${SYFT_VERSION}_linux_arm64.tar.gz"
    syft_sha256="6c0466811541ea03add5213a60a1562f0851e4c0b0ecfdee1a694a9455285900"
    ;;
  "") fail "--architecture is required" ;;
  *) fail "Unsupported architecture: ${ARCHITECTURE}" ;;
esac
[[ -f "$ARCHIVE" ]] || fail "Artifact does not exist: ${ARCHIVE}"
[[ -n "$OUTPUT" ]] || fail "--output is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v zstd >/dev/null 2>&1 || fail "zstd is required"

version="$(ruby -rjson -e 'print JSON.parse(File.binread(ARGV.fetch(0))).fetch("version")' "${SOURCE_DIR}/release.json")"
temporary="$(mktemp -d)"
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

curl --fail --silent --show-error --location \
  "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/${syft_asset}" \
  --output "$temporary/$syft_asset"
printf '%s  %s\n' "$syft_sha256" "$temporary/$syft_asset" | sha256sum --check --status
tar -xzf "$temporary/$syft_asset" -C "$temporary" syft
tar --use-compress-program=unzstd -xf "$ARCHIVE" -C "$temporary"

release_root="$temporary/opt/valpo/releases/$version"
[[ -d "$release_root" ]] || fail "Artifact is missing opt/valpo/releases/${version}"
mkdir -p "$(dirname "$OUTPUT")"
"$temporary/syft" scan "dir:${release_root}" \
  --source-name valpo \
  --source-version "$version" \
  --output "spdx-json=${OUTPUT}"
