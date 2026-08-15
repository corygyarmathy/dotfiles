#!/usr/bin/env bash
# Bump the vendored Quartz plugins to their latest npm releases.
#
# The ~42 first-party plugins are pinned by explicit version + hash in
# plugins.json (see default.nix for why they are vendored at all), so
# `nix flake update` never touches them and nothing else ever will either.
#
# Only the PLUGINS are updated here, deliberately - not Quartz itself.
# default.nix carries a page of workarounds tied to how v5 resolves plugins,
# and the failure mode of getting that wrong is a build that SUCCEEDS and
# produces a silently featureless site. That is exactly the kind of regression
# the CI gate cannot catch, so bumping Quartz stays a deliberate manual act.
#
# npm's own `dist.integrity` is already an SRI string, which is what fetchurl
# wants - so no prefetching is needed and this stays one HTTP request per
# plugin.
#
# Usage:
#   ./update.sh
#
# Output contract (shared by every updater in packages/*):
#   - prints NOTHING when everything is already current
#   - on a change, the FIRST line is a one-line summary used as the PR title,
#     and any further lines are detail for the PR body
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

REGISTRY=https://registry.npmjs.org
PLUGINS=plugins.json

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$PLUGINS" "$tmp/current.json"
cp "$PLUGINS" "$tmp/next.json"

changes=()

for name in $(jq -r 'keys[]' "$tmp/current.json"); do
  current=$(jq -r --arg n "$name" '.[$n].version' "$tmp/current.json")

  meta=$(curl -fsSL "$REGISTRY/@quartz-community%2f$name") || {
    echo "failed to query registry for $name" >&2
    exit 1
  }

  latest=$(jq -r '."dist-tags".latest // empty' <<<"$meta")
  if [ -z "$latest" ]; then
    echo "no dist-tags.latest for $name" >&2
    exit 1
  fi

  [ "$latest" = "$current" ] && continue

  url=$(jq -r --arg v "$latest" '.versions[$v].dist.tarball // empty' <<<"$meta")
  integrity=$(jq -r --arg v "$latest" '.versions[$v].dist.integrity // empty' <<<"$meta")
  if [ -z "$url" ] || [ -z "$integrity" ]; then
    echo "incomplete registry metadata for $name@$latest" >&2
    exit 1
  fi

  jq --sort-keys \
    --arg n "$name" --arg v "$latest" --arg u "$url" --arg h "$integrity" \
    '.[$n] = { version: $v, url: $u, hash: $h }' \
    "$tmp/next.json" > "$tmp/next.json.new"
  mv "$tmp/next.json.new" "$tmp/next.json"

  changes+=("$name: $current -> $latest")
done

if [ ${#changes[@]} -eq 0 ]; then
  exit 0
fi

# jq --sort-keys throughout keeps the diff to the entries that actually moved,
# rather than reshuffling all 42 every run.
mv "$tmp/next.json" "$PLUGINS"

if [ ${#changes[@]} -eq 1 ]; then
  echo "quartz: 1 plugin updated"
else
  echo "quartz: ${#changes[@]} plugins updated"
fi
printf '%s\n' "${changes[@]}"
