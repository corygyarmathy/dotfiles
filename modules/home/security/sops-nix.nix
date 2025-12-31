# SOPS-Nix home-manager secrets
#
# This module handles user-level secrets like:
# - Personal SSH keys
# - API tokens for user applications
# - Credentials for user services
#
# Note: User secrets require a user-accessible age key, typically
# stored in ~/.config/sops/age/keys.txt
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.sops-nix;
in
{
  options.cg.home.sops-nix = {
    enable = lib.mkEnableOption "SOPS-Nix home-manager secrets";

    ageKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
      description = "Path to the age private key file";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      age = {
        keyFile = cfg.ageKeyFile;
        generateKey = false; # Don't auto-generate, we'll create manually
      };

      # Default secrets file for user secrets
      defaultSopsFile = ../../../secrets/secrets.yaml;

      # Define user-level secrets here
      secrets = {
        "private_keys/github" = {
          path = "${config.home.homeDirectory}/.ssh/id_github";
        };

        # Example: Personal API token
        # "tokens/openai" = {
        #   mode = "0600";
        #   path = "${config.home.homeDirectory}/.config/openai/api_key";
        # };
      };
    };

    # Ensure the age key directory exists
    home.activation.setupSopsAge = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$(dirname "${cfg.ageKeyFile}")"
    '';

    home.packages = with pkgs; [
      sops
      age
    ];
  };
}
