#!/usr/bin/env bash
# Bump obsidian-headless to the latest npm release.
#
# The package is pinned by an explicit version string, so `nix flake update`
# never touches it. This regenerates everything that has to move together:
# version, tarball hash, the vendored package-lock.json (the published tarball
# ships none) and npmDepsHash.
#
# Usage:
#   ./update.sh            # bump to dist-tags.latest, no-op if already current
#   ./update.sh 0.0.13     # pin a specific version
#
# Requires nix and network. Prints "obsidian-headless: <old> -> <new>" on a
# change and nothing on a no-op, so CI can branch on the output.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PKG=obsidian-headless
REGISTRY=https://registry.npmjs.org

current=$(sed -n 's/^  version = "\(.*\)";$/\1/p' default.nix)
if [ -z "$current" ]; then
  echo "could not read current version from default.nix" >&2
  exit 1
fi

if [ $# -ge 1 ]; then
  target="$1"
else
  target=$(curl -fsSL "$REGISTRY/$PKG" | jq -r '."dist-tags".latest')
fi

if [ "$target" = "$current" ]; then
  echo "already at $current" >&2
  exit 0
fi

# npm's own integrity string is already SRI, which is what fetchurl wants.
integrity=$(curl -fsSL "$REGISTRY/$PKG" | jq -r --arg v "$target" '.versions[$v].dist.integrity')
if [ -z "$integrity" ] || [ "$integrity" = "null" ]; then
  echo "no such version: $target" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/pkg.tgz" "$REGISTRY/$PKG/-/$PKG-$target.tgz"
tar xzf "$tmp/pkg.tgz" -C "$tmp"

# --ignore-scripts: better-sqlite3's install hook would try to fetch a prebuilt
# binary, and we only want the resolved dependency graph here anyway.
( cd "$tmp/package" && npm install --package-lock-only --ignore-scripts >/dev/null 2>&1 )
cp "$tmp/package/package-lock.json" ./package-lock.json

deps_hash=$(nix run --extra-experimental-features 'nix-command flakes' \
  nixpkgs#prefetch-npm-deps -- ./package-lock.json 2>/dev/null | tail -1)
if [ -z "$deps_hash" ]; then
  echo "prefetch-npm-deps produced no hash" >&2
  exit 1
fi

sed -i \
  -e "s|^  version = \".*\";$|  version = \"$target\";|" \
  -e "s|^    hash = \"sha512-.*\";$|    hash = \"$integrity\";|" \
  -e "s|^  npmDepsHash = \".*\";$|  npmDepsHash = \"$deps_hash\";|" \
  default.nix

# Cheap guard against a sed that matched nothing: all three must now be present.
grep -q "version = \"$target\";" default.nix
grep -q "hash = \"$integrity\";" default.nix
grep -q "npmDepsHash = \"$deps_hash\";" default.nix

echo "$PKG: $current -> $target"
