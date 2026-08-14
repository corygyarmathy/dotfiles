# obsidian-headless: the Obsidian Sync headless CLI (`ob`).
#
# Not in nixpkgs and published only to npm (proprietary, UNLICENSED), so we
# build it from the registry tarball with buildNpmPackage. The published
# tarball ships no lockfile, so the package-lock.json generated alongside this
# file is copied in before `npm ci`.
#
# `better-sqlite3` is the one native dependency: it is compiled from source
# here (python3 + node-gyp). The prebuilt binaries it would otherwise download
# via prebuild-install won't run on NixOS, and there is no network during the
# build, so `npm_config_build_from_source` forces the source path directly.
{
  lib,
  buildNpmPackage,
  fetchurl,
  nodejs_22,
  python3,
}:

buildNpmPackage rec {
  pname = "obsidian-headless";
  version = "0.0.14";

  src = fetchurl {
    url = "https://registry.npmjs.org/obsidian-headless/-/obsidian-headless-${version}.tgz";
    hash = "sha512-S1d/hxLKvCUG2g5tRyXFkzPqMs3Ntw1tDyzoF2yfHGRuB4B+Mi3X2vgT8LbfQKrkEEi3LfJRdXtYzAVHcbpccw==";
  };

  # npm tarballs unpack into ./package
  sourceRoot = "package";

  # The published tarball has no lockfile; provide the one we generated.
  postPatch = ''
    cp ${./package-lock.json} ./package-lock.json
  '';

  # Regenerate whenever version changes (the lockfile is ours, not upstream's):
  #   nix run nixpkgs#prefetch-npm-deps -- packages/obsidian-headless/package-lock.json
  npmDepsHash = "sha256-Pcy6hxgc9MyTe/a7bE4pMtXjG9hx4HNwZgbfIzTtVRQ=";

  nodejs = nodejs_22; # package requires node >= 22

  # better-sqlite3 builds its native addon via node-gyp.
  nativeBuildInputs = [ python3 ];
  env.npm_config_build_from_source = "true";

  # No build script; we only want the deps installed and the `ob` bin linked.
  dontNpmBuild = true;

  meta = {
    description = "Headless client for Obsidian Sync";
    homepage = "https://obsidian.md/help/sync/headless";
    license = lib.licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "ob";
  };
}
