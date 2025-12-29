# Direnv for per-directory environments
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.direnv;
in {
  options.cg.home.direnv.enable = lib.mkEnableOption "Direnv";

  config = lib.mkIf cfg.enable {
    programs.direnv = {
      enable = true;
      enableBashIntegration = true;
      nix-direnv.enable = true;
      config = {
        global = {
          hide_env_diff = true;
        };
      };
    };
  };
}
