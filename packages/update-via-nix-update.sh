#!/usr/bin/env bash
# Run nix-update so that it satisfies the updater contract used by
# .github/workflows/package-update.yml.
#
# nix-update is the right tool - it knows how to move a version, refresh
# src.hash and rehash npmDeps/cargoDeps/vendorDir - but it narrates
# unconditionally to stdout:
#
#   $ nix-instantiate --eval --json --strict /nix/store/...
#   fetch https://github.com/erikkaashoek/Comskip/releases.atom
#   Not updating version, already 0.83
#
# The contract is "print nothing when already current, and on a change print a
# one-line summary as the first line". Left unwrapped, nix-update never prints
# nothing - and on a real update that narration would become the PR title.
#
# Usage (from passthru.updateScript, argv-style):
#   update-via-nix-update.sh <nix-update-binary> <attr> [extra nix-update args...]
#
# The binary is passed in rather than looked up on PATH so the version of
# nix-update is pinned by the flake like everything else.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

if [ $# -lt 2 ]; then
  echo "usage: $0 <nix-update-binary> <attr> [args...]" >&2
  exit 2
fi

nix_update="$1"
shift
attr="$1"
shift

version_of() {
  nix eval --raw ".#packages.x86_64-linux.$attr.version"
}

before="$(version_of)"

# Swallow the narration, but keep it for the failure path - a silent failure
# here would look identical to "already current".
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! "$nix_update" --flake "$@" "$attr" >"$log" 2>&1; then
  echo "nix-update failed for $attr:" >&2
  cat "$log" >&2
  exit 1
fi

after="$(version_of)"

[ "$before" = "$after" ] && exit 0

echo "$attr: $before -> $after"
