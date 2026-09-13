# The Go AFK agent, `afk`, from corygyarmathy/afk-agent.
#
# `src` is the flake input rather than a fetcher here, so the pin lives in
# flake.lock with every other input and moves with `nix flake update`. That is
# also why this package has no `passthru.autoUpdate`: package-update.yml is for
# what `nix flake update` cannot reach.
{
  lib,
  buildGoModule,
  src,
}:
buildGoModule (finalAttrs: {
  pname = "afk-agent";
  # A flake input with `flake = false` still carries its revision.
  version = "0-unstable-${src.shortRev or "dirty"}";
  inherit src;

  # The one dependency, the SQLite driver, is vendored in-tree (its ADR 0004),
  # so there is nothing to fetch and no hash to keep.
  vendorHash = null;

  subPackages = [ "cmd/afk" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/corygyarmathy/afk-agent/internal/cli.Version=${finalAttrs.version}"
  ];

  # buildGoModule tests only `subPackages`, and `cmd/afk` has no tests. The
  # agent's suite is its own repository's gate, run on every change to its
  # protected master before a lock bump can pick that change up.

  meta = {
    description = "Unattended agent that takes work from a tracker and leaves a pull request";
    homepage = "https://github.com/corygyarmathy/afk-agent";
    mainProgram = "afk";
    platforms = lib.platforms.linux;
  };
})
