#!/usr/bin/env bash
set -euo pipefail
umask 077

REPOSITORY="holamendi/valpo"
REF="main"
WORK_DIR=""

usage() {
  cat <<USAGE
Usage: curl -fsSL https://raw.githubusercontent.com/${REPOSITORY}/main/packaging/bootstrap.sh | sudo bash

Options:
  -h, --help  Show this help
USAGE
}

log() {
  printf '[valpo-bootstrap] %s\n' "$*"
}

fail() {
  printf '[valpo-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
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

[[ "${EUID}" -eq 0 ]] || fail "This installer must run as root. Pipe it to sudo bash."
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"

WORK_DIR="$(mktemp -d)"
trap cleanup EXIT
ARCHIVE_PATH="${WORK_DIR}/valpo.tar.gz"
SOURCE_DIR="${WORK_DIR}/source"
ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/${REF}.tar.gz"

log "Downloading ${REPOSITORY}@${REF}"
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$ARCHIVE_PATH" \
  -- "$ARCHIVE_URL"

mkdir "$SOURCE_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$SOURCE_DIR" --strip-components=1
[[ -f "${SOURCE_DIR}/packaging/install.sh" ]] || fail "Downloaded archive does not contain the Valpo installer"

log "Running the Valpo source installer"
bash "${SOURCE_DIR}/packaging/install.sh"
