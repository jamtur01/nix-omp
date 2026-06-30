#!/usr/bin/env bash
# Bump VERSION.json to the latest oh-my-pi release and refresh every per-platform
# binary hash. Requires `gh`, `nix`, and `jq` on PATH.
set -euo pipefail

repo="can1357/oh-my-pi"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_file="$here/VERSION.json"

tag="$(gh release view --repo "$repo" --json tagName --jq .tagName)"
version="${tag#v}"
echo "latest release: $tag"

declare -A assets=(
  [aarch64-darwin]=omp-darwin-arm64
  [x86_64-darwin]=omp-darwin-x64
  [aarch64-linux]=omp-linux-arm64
  [x86_64-linux]=omp-linux-x64
)

hashes_json="{}"
for system in "${!assets[@]}"; do
  url="https://github.com/$repo/releases/download/$tag/${assets[$system]}"
  echo "prefetching $system ($url)"
  hash="$(nix store prefetch-file --hash-type sha256 --json "$url" | jq -r .hash)"
  hashes_json="$(jq --arg s "$system" --arg h "$hash" '.[$s] = $h' <<<"$hashes_json")"
done

jq -n --arg version "$version" --argjson hashes "$hashes_json" \
  '{version: $version, hashes: $hashes}' >"$version_file"

echo "wrote $version_file"
