# Caddy with the plugins the reverse proxy needs.
#
# The plugin pins and the vendor `hash` must move together: the hash covers the
# vendored Go modules for exactly these pins, and it drifts even under a pinned
# nixpkgs because transitive dependencies resolve at build time
# (https://github.com/nixos/nixpkgs/issues/450289). Bumping a pin - or taking a
# nixpkgs Caddy bump - without rehashing is a red gate on every host, as in
# #229. Both are refreshed by ./update.sh, which is also this package's
# passthru.updateScript for .github/workflows/package-update.yml, so the weekly
# updater proposes the next hash rather than a broken CI run.
{ caddy }:

(caddy.withPlugins {
  plugins = [
    "github.com/caddy-dns/cloudflare@v0.2.4"
    "github.com/mholt/caddy-ratelimit@v0.1.0"
  ];
  # Refreshed by ./update.sh - never hand-edit.
  hash = "sha256-aYsGQTUvBNC24YCLqGZ+1BR0rpmtkZ1oNL/TVpMEuhg=";
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      # Opt in to .github/workflows/package-update.yml. Explicit rather than
      # inferred from updateScript's presence: nixpkgs' buildPythonApplication
      # sets a default updateScript of its own, so every Python package here
      # would otherwise be picked up and "updated" against no upstream at all.
      autoUpdate = true;

      # A stale hash reds the whole gate (every host builds Caddy), and the diff
      # is a version string plus a SHA no review can validate - the same argument
      # dependabot-auto-merge.yml makes for action pins. --auto only sets the
      # intent; the required `nixos ci` check (host builds plus the
      # reverse-proxy VM test, which boots this binary against the generated
      # Caddyfile) still gates the merge. Packages that cross an upstream release
      # boundary on "it built" evidence alone (comskip, obsidian-headless) stay
      # manual, per ADR 0001.
      autoMerge = true;

      # Repo-relative rather than a store path: the script edits the plugin pins
      # in this directory, which nix-update cannot do.
      updateScript = [ "packages/caddy-with-plugins/update.sh" ];
    };
  })
