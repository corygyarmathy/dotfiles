# nix-update for the packages that update through
# packages/update-via-nix-update.sh, patched to work under lazy trees.
#
# Nix no longer copies a local flake into the store for `nix flake metadata`,
# but nix-update evaluates the store path that command reports, so every run
# that reached a package failed with a missing `/nix/store/...-source`.
# Copying the flake beforehand is not enough: nix-update re-evaluates after
# editing the package, and the edited tree has a new path.
#
# The patch is upstream's open fix (Mic92/nix-update#692, for #687), less its
# test, which runs `nix` and cannot run in the build sandbox. Drop this package
# and go back to the nixpkgs one once a nix-update release carries the fix.
{ nix-update }:

nix-update.overridePythonAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./lazy-flake-source.patch ];
})
