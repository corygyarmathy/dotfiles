# SOPS-Nix home-manager secrets
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.cg.home.sops-nix;
in {
  options.cg.home.sops-nix.enable = lib.mkEnableOption "SOPS-Nix home-manager secrets";

  config = lib.mkIf cfg.enable {
    sops = {
      age = {
        keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
        generateKey = false;
      };

      # Define user-specific secrets here
      # secrets = {
      #   "tokens/github" = {
      #     mode = "0600";
      #     path = "${config.home.homeDirectory}/.config/github/token";
      #   };
      # };
    };

    # Ensure the age key directory exists
    home.activation.setupSopsAge = lib.hm.dag.entryAfter ["writeBoundary"] ''
      $DRY_RUN_CMD mkdir -p $HOME/.config/sops/age
    '';
  };
}
