#!/usr/bin/env bash
set -euo pipefail
# A failed upload stays draft. Never replace assets or reuse a published tag.
tag="${1:?release tag required}"
directory="${2:?asset directory required}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo 'Invalid release tag' >&2; exit 1; }
repo=holamendi/valpo
# Repository administrators must enable immutable releases before tagging.
version="${tag#v}"
assets=("$directory/SHA256SUMS")
for arch in amd64 arm64; do
  for suffix in tar.zst spdx.json provenance.intoto.jsonl sbom.intoto.jsonl; do
    asset="$directory/valpo-$version-linux-$arch.$suffix"
    [[ -s "$asset" ]] || { echo "Missing release asset: $asset" >&2; exit 1; }
    assets+=("$asset")
  done
done
(cd "$directory" && sha256sum --check SHA256SUMS)
# create fails for existing releases, including abandoned drafts; inspect those
# manually rather than allowing a rerun to overwrite any release identity.
flags=(--latest=false)
[[ "$version" != *-* ]] || flags+=(--prerelease)
gh release create "$tag" --repo "$repo" --verify-tag --draft --title "Valpo $tag" \
  --notes "Native Ubuntu 26.04 archives, checksums, SBOMs, and verified build provenance." "${flags[@]}"
gh release upload "$tag" --repo "$repo" "${assets[@]}"
gh release edit "$tag" --repo "$repo" --draft=false
[[ "$(gh api "repos/$repo/releases/tags/$tag" --jq '.immutable')" == true ]] || {
  echo 'Published release was not made immutable' >&2
  exit 1
}
