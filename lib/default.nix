# Helper functions for this NixOS configuration
{ lib, ... }:
rec {
  # ===========================================================================
  # Auto-Import Helpers
  # ===========================================================================

  # Import all .nix files from a directory (non-recursive)
  # Excludes default.nix to avoid circular imports
  # Usage: imports = importDir ./modules/nixos;
  importDir =
    dir:
    let
      files = builtins.readDir dir;
      nixFiles = lib.filterAttrs (
        name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix"
      ) files;
    in
    map (name: dir + "/${name}") (builtins.attrNames nixFiles);

  # Import all .nix files from a directory recursively
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

  # ===========================================================================
  # Module Creation Helpers
  # ===========================================================================

  # Helper to create a simple home-manager module with enable option
  # Usage: mkHomeModule { name = "foo"; config = { ... }; }
  mkHomeModule =
    {
      name,
      description ? "enables ${name}",
      config,
    }:
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      cfg = config.cg.home.${name};
    in
    {
      options.cg.home.${name} = {
        enable = lib.mkEnableOption description;
      };
      config = lib.mkIf cfg.enable config;
    };

  # Helper to create a simple NixOS module with enable option
  # Usage: mkNixosModule { name = "foo"; config = { ... }; }
  mkNixosModule =
    {
      name,
      description ? "enables ${name}",
      config,
    }:
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      cfg = config.cg.${name};
    in
    {
      options.cg.${name} = {
        enable = lib.mkEnableOption description;
      };
      config = lib.mkIf cfg.enable config;
    };
}
