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
  version = "0.0.10";

  src = fetchurl {
    url = "https://registry.npmjs.org/obsidian-headless/-/obsidian-headless-${version}.tgz";
    hash = "sha512-rs90kHkX9uJNPf6fMGQoNRw9KTA+cpkBbPG2Un5iT1IZxdpW1+yaBrONbsc2t5KHpbc+s5G7/krz0VoUn+r5nw==";
  };

  # npm tarballs unpack into ./package
  sourceRoot = "package";

  # The published tarball has no lockfile; provide the one we generated.
  postPatch = ''
    cp ${./package-lock.json} ./package-lock.json
  '';

  # Placeholder. Replace with the real value on the first build, e.g.
  #   nix run nixpkgs#prefetch-npm-deps -- packages/obsidian-headless/package-lock.json
  # or build once with lib.fakeHash and copy the hash Nix reports.
  npmDepsHash = "sha256-vg1udNOnkp/pnzf4VXJUe90biQsu3AOwGVOw4FQM+3g=";

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
