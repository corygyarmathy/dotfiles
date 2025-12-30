# Helper functions for this NixOS configuration
{lib, ...}: {
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
  # Traverses subdirectories and imports all .nix files (except default.nix)
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
          # Recurse into subdirectories
          importDirRecursive modulePath
        else if type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix" then
          # Import .nix files (except default.nix)
          [ modulePath ]
        else
          # Ignore other files
          [ ];
    in
    lib.flatten (lib.mapAttrsToList processEntry files);

  # Helper to create a simple home-manager module with enable option
  # Usage: mkHomeModule { name = "foo"; config = { ... }; }
  mkHomeModule = {
    name,
    description ? "enables ${name}",
    config,
  }: {
    pkgs,
    lib,
    config,
    ...
  }: let
    cfg = config.cg.home.${name};
  in {
    options.cg.home.${name} = {
      enable = lib.mkEnableOption description;
    };
    config = lib.mkIf cfg.enable config;
  };

  # Helper to create a simple NixOS module with enable option
  # Usage: mkNixosModule { name = "foo"; config = { ... }; }
  mkNixosModule = {
    name,
    description ? "enables ${name}",
    config,
  }: {
    pkgs,
    lib,
    config,
    ...
  }: let
    cfg = config.cg.${name};
  in {
    options.cg.${name} = {
      enable = lib.mkEnableOption description;
    };
    config = lib.mkIf cfg.enable config;
  };
}
