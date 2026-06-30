#!/usr/bin/env bash
# Bump VERSION.json to the latest oh-my-pi release. Reads the per-asset sha256
# digests straight from the GitHub release API and converts them to SRI hashes,
# so nothing is downloaded. Requires `gh`, `nix`, and `jq` on PATH.
set -euo pipefail

repo="can1357/oh-my-pi"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_file="$here/VERSION.json"

# system -> release asset name
declare -A assets=(
  ["aarch64-darwin"]=omp-darwin-arm64
  ["x86_64-darwin"]=omp-darwin-x64
  ["aarch64-linux"]=omp-linux-arm64
  ["x86_64-linux"]=omp-linux-x64
)

release="$(gh api "repos/$repo/releases/latest")"
tag="$(jq -r .tag_name <<<"$release")"
version="${tag#v}"
echo "latest release: $tag"

hashes_json="{}"
for system in "${!assets[@]}"; do
  digest="$(jq -r --arg n "${assets[$system]}" \
    '.assets[] | select(.name == $n) | .digest' <<<"$release")"
  if [[ "$digest" != sha256:* ]]; then
    echo "error: no sha256 digest for ${assets[$system]} in $tag" >&2
    exit 1
  fi
  hash="$(nix hash convert --hash-algo sha256 --to sri "$digest")"
  echo "  $system  $hash"
  hashes_json="$(jq --arg s "$system" --arg h "$hash" '.[$s] = $h' <<<"$hashes_json")"
done

jq -n --arg version "$version" --argjson hashes "$hashes_json" \
  '{version: $version, hashes: $hashes}' >"$version_file"

echo "wrote $version_file"
