#!/usr/bin/env bash
# Refresh the Caddy plugin pins and the withPlugins vendor hash in default.nix.
#
# Both have to move together: the hash covers the vendored Go modules for
# exactly the pinned plugins, and it drifts even under a pinned nixpkgs because
# transitive dependencies resolve at build time
# (https://github.com/nixos/nixpkgs/issues/450289). One script does both so one
# weekly PR carries both; the summary names each part so a plugin crossing a
# release boundary reads differently from a hash-only refresh.
#
# Usage:
#   packages/caddy-with-plugins/update.sh   # refresh pins + hash, no-op if current
#
# Requires nix, git and network. Prints nothing on stdout when already current;
# on a change the first stdout line is a one-line summary (the updater contract
# in .github/workflows/package-update.yml) and any further lines are detail for
# the PR body.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/../.." # repo root, wherever invoked from
FILE="packages/caddy-with-plugins/default.nix"

latest_tag() { # $1 = owner/repo
	# Stable tags only: a prerelease is never proposed unattended.
	git ls-remote --tags --refs "https://github.com/$1" 2>/dev/null |
		sed -n 's|.*refs/tags/||p' |
		grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' |
		sort -V |
		tail -1
}

summaries=()

# 1. Plugin pins. The module path implies the repo (github.com/<owner>/<repo>).
specs="$(grep -o '"github\.com/[^"]*@[^"]*"' "$FILE" | tr -d '"' || true)"
if [ -z "$specs" ]; then
	echo "no plugin pins found in $FILE" >&2
	exit 1
fi
while read -r spec; do
	mod="${spec%@*}"
	current="${spec#*@}"
	repo="${mod#github.com/}"
	latest="$(latest_tag "$repo")"
	if [ -z "$latest" ]; then
		echo "could not list tags for $repo" >&2
		exit 1
	fi
	if [ "$latest" != "$current" ]; then
		sed -i "s|\"$mod@$current\"|\"$mod@$latest\"|" "$FILE"
		summaries+=("$repo $current -> $latest")
	fi
done <<<"$specs"

# 2. Vendor hash: rebuild; on a mismatch adopt the hash Nix reports, then verify.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if nix build --no-link --print-build-logs ".#caddy-with-plugins" >"$log" 2>&1; then
	:
else
	got="$(grep -m1 'got:' "$log" | grep -o 'sha256-[A-Za-z0-9+/=]*' || true)"
	if [ -z "$got" ]; then
		echo "caddy-with-plugins build failed for another reason:" >&2
		tail -n 30 "$log" >&2
		exit 1
	fi
	old_hash="$(sed -n 's/^[[:space:]]*hash = "\(sha256-[^"]*\)";$/\1/p' "$FILE")"
	sed -i "s|hash = \"$old_hash\"|hash = \"$got\"|" "$FILE"
	if ! nix build --no-link --print-build-logs ".#caddy-with-plugins" >"$log" 2>&1; then
		echo "rebuild with refreshed hash still fails:" >&2
		tail -n 30 "$log" >&2
		exit 1
	fi
	summaries+=("vendor hash ${old_hash:0:15} -> ${got:0:15}")
fi

[ "${#summaries[@]}" -gt 0 ] || {
	echo "caddy-with-plugins is already current" >&2
	exit 0
}

# Trust the working tree, not the narration.
if git diff --quiet -- "$FILE"; then
	echo "caddy-with-plugins printed a summary but changed no files" >&2
	exit 0
fi

{
	summary="$(printf '%s; ' "${summaries[@]}")"
	echo "caddy-with-plugins: ${summary%; }"
	git diff -- "$FILE"
}
