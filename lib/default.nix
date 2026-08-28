# Helper functions for this NixOS configuration.
#
# One function, deliberately. Three others lived here - `importDir`,
# `mkHomeModule` and `mkNixosModule` - and none of them had ever been called;
# `mkHomeModule` shadowed its own `config` argument and could not have worked
# if it were. A helper nothing uses is a claim about how this repository is
# built that the repository does not honour, which is worse than no helper.
{ lib, ... }:
rec {
  # Import all .nix files from a directory recursively.
  # Traverses subdirectories and imports all .nix files (except default.nix, and
  # except anything under a `lib` directory - see below)
  # Usage: imports = importDirRecursive ./modules/home;
  importDirRecursive =
    dir:
    let
      files = builtins.readDir dir;

      # Process each entry in the directory
      processEntry =
        name: type:
        let
          modulePath = dir + "/${name}";
        in
        if type == "directory" then
          # A `lib` directory holds helpers for the modules beside it, not
          # modules - a NixOS module is a function of { config, lib, pkgs, ... }
          # and a helper is not, so importing one as a module fails with an
          # unhelpful "called with unexpected argument 'self'". Skipped by name
          # rather than by inspection, because deciding by inspection means
          # evaluating the file to find out.
          if name == "lib" then [ ] else importDirRecursive modulePath
        else if type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix" then
          # Import .nix files (except default.nix)
          [ modulePath ]
        else
          # Ignore other files
          [ ];
    in
    lib.flatten (lib.mapAttrsToList processEntry files);
}
