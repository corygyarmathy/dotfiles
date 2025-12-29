# Helper functions for this NixOS configuration
{lib, ...}: {
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
