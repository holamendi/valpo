# syntax=docker/dockerfile:1.7

FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b AS ruby-runtime

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH
ARG VALPO_VERSION
ARG RUBY_VERSION=4.0.5

ENV DEBIAN_FRONTEND=noninteractive
ENV MISE_VERSION=2026.6.0
ENV MISE_YES=1
ENV MISE_LOCKED=1
ENV MISE_RUBY_COMPILE=false
ENV MISE_RUBY_GITHUB_ATTESTATIONS=true

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    tar \
    zstd \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /source

COPY .mise.toml mise.lock ./

RUN <<'SCRIPT'
set -euo pipefail

case "$TARGETARCH" in
  amd64)
    mise_asset="mise-v${MISE_VERSION}-linux-x64"
    mise_sha256="9d225e07427b7e05cc4ae7f09f111dfdefdfebb58956513403711935ce313202"
    expected_machine=x86_64
    ;;
  arm64)
    mise_asset="mise-v${MISE_VERSION}-linux-arm64"
    mise_sha256="2fb6a31e85d43ee1245d45e8d659d759b1c6100f01deeae5f918fa8932330f55"
    expected_machine=aarch64
    ;;
  *)
    printf 'Unsupported Docker target architecture: %s\n' "$TARGETARCH" >&2
    exit 1
    ;;
esac

test "$(uname -m)" = "$expected_machine"
curl --fail --silent --show-error --location \
  "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${mise_asset}" \
  --output /usr/local/bin/mise
printf '%s  %s\n' "$mise_sha256" /usr/local/bin/mise | sha256sum --check --status
chmod 0755 /usr/local/bin/mise

release_root="/opt/valpo/releases/${VALPO_VERSION}"
export HOME=/tmp/valpo-release-home
export MISE_DATA_DIR="${release_root}/.mise-build"
export MISE_CACHE_DIR=/tmp/valpo-mise-cache
export MISE_STATE_DIR=/tmp/valpo-mise-state
install -d -m 0755 "$HOME" "$release_root/runtime"

install_log=/tmp/valpo-mise-install.log
if ! mise install --locked "ruby@${RUBY_VERSION}" 2>&1 | tee "$install_log"; then
  exit 1
fi
if grep -Eiq 'ruby-build|building ruby|compiling ruby|installing ruby from source' "$install_log"; then
  printf 'mise attempted to compile Ruby from source\n' >&2
  exit 1
fi

ruby_source="${MISE_DATA_DIR}/installs/ruby/${RUBY_VERSION}"
test -x "${ruby_source}/bin/ruby"
mv "$ruby_source" "$release_root/runtime/ruby"
rm -rf "$MISE_DATA_DIR" "$MISE_CACHE_DIR" "$MISE_STATE_DIR" "$HOME"
rm -f /usr/local/bin/mise "$install_log"

ruby_home="$release_root/runtime/ruby"
mise_rubygems_plugin="$ruby_home/lib/ruby/site_ruby/rubygems_plugin.rb"
if [[ -f "$mise_rubygems_plugin" ]]; then
  grep -F 'mise' "$mise_rubygems_plugin" >/dev/null || {
    printf 'Refusing to remove an unrecognized RubyGems site plugin\n' >&2
    exit 1
  }
  rm -f "$mise_rubygems_plugin"
fi

test "$($ruby_home/bin/ruby -e 'print RUBY_VERSION')" = "$RUBY_VERSION"
test ! -e "$release_root/.mise-build"
test ! -e "$mise_rubygems_plugin"
SCRIPT

FROM ruby-runtime AS gems

ARG VALPO_VERSION
ARG BUNDLER_VERSION=4.0.10

# The locked graph includes source-only native gems. Compile them in this
# disposable native stage; the artifact-producing stage has no compiler.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/valpo/releases/${VALPO_VERSION}

COPY Gemfile Gemfile.lock valpo.gemspec ./
COPY lib ./lib

RUN <<'SCRIPT'
set -euo pipefail
release_root="/opt/valpo/releases/${VALPO_VERSION}"
ruby_home="$release_root/runtime/ruby"
export HOME=/tmp/valpo-gem-home
export PATH="${ruby_home}/bin:${PATH}"
install -d -m 0700 "$HOME"

gem install bundler --version "$BUNDLER_VERSION" --no-document
bundle "_${BUNDLER_VERSION}_" config set --local path "$release_root/bundle"
bundle "_${BUNDLER_VERSION}_" config set --local frozen true
bundle "_${BUNDLER_VERSION}_" config set --local without 'development:test'
bundle "_${BUNDLER_VERSION}_" install --standalone=default --jobs 4 --retry 3
find "$release_root/bundle" -type d \( -name cache -o -name doc \) -prune -exec rm -rf {} +
find "$release_root/bundle" -type f \( -name '*.o' -o -name mkmf.log \) -delete
test -r "$release_root/bundle/bundler/setup.rb"
SCRIPT

FROM ruby-runtime AS build

ARG TARGETARCH
ARG VALPO_VERSION
ARG RUBY_VERSION=4.0.5
ARG SOURCE_DATE_EPOCH

WORKDIR /source

COPY Gemfile Gemfile.lock valpo.gemspec release.json LICENSE mise.lock ./
COPY lib ./lib
COPY exe ./exe
COPY db ./db
COPY packaging/valpo.yml.example ./packaging/valpo.yml.example
COPY packaging/release/launcher.sh ./packaging/release/launcher.sh
COPY packaging/upgrade.sh ./packaging/upgrade.sh
COPY packaging/upgrade/upgrader.rb packaging/upgrade/probe.rb ./packaging/upgrade/
COPY --from=gems /opt/valpo/releases/${VALPO_VERSION}/bundle /opt/valpo/releases/${VALPO_VERSION}/bundle

RUN <<'SCRIPT'
set -euo pipefail

case "$TARGETARCH" in
  amd64)
    pack_asset="pack-v0.40.8-linux.tgz"
    pack_sha256="3b8cfd4287ea6c648ccff9c17cbfa61ae615839071a5de804f3b84316ed99a93"
    ;;
  arm64)
    pack_asset="pack-v0.40.8-linux-arm64.tgz"
    pack_sha256="51b1b8ba93f3cff0e25fdc4c099daddd962ea2c691ccd13bd607f0a452c42039"
    ;;
  *)
    printf 'Unsupported Docker target architecture: %s\n' "$TARGETARCH" >&2
    exit 1
    ;;
esac

release_root="/opt/valpo/releases/${VALPO_VERSION}"
ruby_home="$release_root/runtime/ruby"
rm -rf \
  "$ruby_home/include" \
  "$ruby_home/share/doc" \
  "$ruby_home/share/man" \
  "$ruby_home/share/ri"
find "$ruby_home/lib/ruby/gems" -type d \( -name cache -o -name doc -o -name docs \) -prune -exec rm -rf {} +
find "$ruby_home/lib/ruby/gems" -type d \( -name test -o -name spec -o -name man -o -name include \) -prune -exec rm -rf {} +
find "$release_root/bundle" -type d \( -name test -o -name spec -o -name man -o -name doc -o -name docs -o -name include \) -prune -exec rm -rf {} +
rm -rf "$ruby_home/lib/ruby/4.0.0/bundler/man"
find "$ruby_home" -type f -name '*.a' -delete

cp -a \
  Gemfile \
  Gemfile.lock \
  LICENSE \
  db \
  exe \
  lib \
  mise.lock \
  packaging \
  release.json \
  valpo.gemspec \
  "$release_root/"

install -d -m 0755 "$release_root/tools" "$release_root/bin"
temporary_pack=/tmp/valpo-pack.tgz
curl --fail --silent --show-error --location \
  "https://github.com/buildpacks/pack/releases/download/v0.40.8/${pack_asset}" \
  --output "$temporary_pack"
printf '%s  %s\n' "$pack_sha256" "$temporary_pack" | sha256sum --check --status
tar -xzf "$temporary_pack" -C "$release_root/tools" pack
chmod 0755 "$release_root/tools/pack"
rm -f "$temporary_pack"

for launcher in valpo valpo-api valpo-maintenance valpo-migrate valpo-worker; do
  install -m 0755 packaging/release/launcher.sh "$release_root/bin/$launcher"
done

find "$release_root" -type d -exec chmod 0755 {} +
find "$release_root" -type f ! -perm /111 -exec chmod 0644 {} +
find "$release_root" -type f -perm /111 -exec chmod 0755 {} +

for development_gem in minitest rack-test standard rubocop rubocop-ast rubocop-performance; do
  if find "$release_root/bundle" -type d -path "*/gems/${development_gem}-*" -print -quit | grep -q .; then
    printf 'Development gem leaked into release: %s\n' "$development_gem" >&2
    exit 1
  fi
done

test ! -e "$release_root/.mise-build"
test ! -e "$release_root/runtime/ruby/lib/ruby/site_ruby/rubygems_plugin.rb"
test ! -e "$release_root/runtime/ruby/include"
test ! -e "$release_root/runtime/ruby/share/ri"
test -z "$(find "$release_root/runtime/ruby" -type f -name '*.a' -print -quit)"
test -r "$release_root/bundle/bundler/setup.rb"

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

extracted_kib="$(du -sk "$release_root" | awk '{print $1}')"
if (( extracted_kib > 275 * 1024 )); then
  printf 'Extracted artifact is too large: %s KiB (limit: %s KiB)\n' "$extracted_kib" "$((275 * 1024))" >&2
  exit 1
fi

archive="valpo-${VALPO_VERSION}-linux-${TARGETARCH}.tar.zst"
install -d -m 0755 /dist
tar \
  --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  --use-compress-program='zstd -10 -T1' \
  -cf "/dist/${archive}" \
  -C / "opt/valpo/releases/${VALPO_VERSION}"

compressed_bytes="$(stat --format='%s' "/dist/${archive}")"
if (( compressed_bytes > 75 * 1024 * 1024 )); then
  printf 'Compressed artifact is too large: %s bytes (limit: %s bytes)\n' "$compressed_bytes" "$((75 * 1024 * 1024))" >&2
  exit 1
fi

printf 'Built %s: %s bytes compressed, %s KiB extracted\n' \
  "$archive" "$compressed_bytes" "$extracted_kib"
SCRIPT

FROM scratch AS artifact
COPY --from=build /dist/ /
