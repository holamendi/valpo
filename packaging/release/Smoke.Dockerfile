# syntax=docker/dockerfile:1.7

FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG ARCHIVE
ARG ARCHITECTURE
ARG VALPO_VERSION

ENV DEBIAN_FRONTEND=noninteractive

COPY packaging/release/runtime-packages.txt /tmp/runtime-packages.txt
RUN apt-get update \
  && grep -Ev '^[[:space:]]*(#|$)' /tmp/runtime-packages.txt | xargs apt-get install -y --no-install-recommends \
  && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt

COPY ${ARCHIVE} /tmp/valpo-release.tar.zst
COPY packaging/release/smoke_container.sh /usr/local/bin/valpo-release-smoke

RUN <<'SCRIPT'
set -euo pipefail
expected_root="opt/valpo/releases/${VALPO_VERSION}"
while IFS= read -r entry; do
  case "$entry" in
    /*|..|../*|*/..|*/../*)
      printf 'Unsafe archive entry: %s\n' "$entry" >&2
      exit 1
      ;;
  esac
  case "$entry" in
    "$expected_root"|"$expected_root"/*) ;;
    *)
      printf 'Archive entry is outside %s: %s\n' "$expected_root" "$entry" >&2
      exit 1
      ;;
  esac
done < <(tar --use-compress-program=unzstd -tf /tmp/valpo-release.tar.zst)
tar --use-compress-program=unzstd -xf /tmp/valpo-release.tar.zst -C /
rm -f /tmp/valpo-release.tar.zst

release_root="/${expected_root}"
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  case "$target" in
    /*)
      printf 'Absolute symlink is not allowed: %s -> %s\n' "$link" "$target" >&2
      exit 1
      ;;
  esac
  resolved="$(realpath -m "$(dirname "$link")/$target")"
  case "$resolved" in
    "$release_root"|"$release_root"/*) ;;
    *)
      printf 'Escaping symlink is not allowed: %s -> %s\n' "$link" "$target" >&2
      exit 1
      ;;
  esac
done < <(find "$release_root" -type l -print0)

chmod 0755 /usr/local/bin/valpo-release-smoke
SCRIPT

RUN --network=none /usr/local/bin/valpo-release-smoke "$VALPO_VERSION" "$ARCHITECTURE"
