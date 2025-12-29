{
  lib,
  config,
  inputs,
  ...
}:
{
  imports = [
    inputs.sops-nix.homeManagerModules.sops
  ];

  options = {
    cg.home.sops-nix.enable = lib.mkEnableOption "enables home-manager options of sops-nix";
  };

  config = lib.mkIf config.cg.home.sops-nix.enable {
    sops = {
      # Use a separate secrets file for user-specific secrets
      # defaultSopsFile = ../secrets/home-secrets.yaml;

      # The age key should be provided by the system
      age = {
        keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
        generateKey = false; # Don't generate, use system-provided
      };

      # Define any user-specific secrets here
      secrets = {
        # Example: API tokens, personal configs, etc.
        "tokens/github" = {
          mode = "0600";
          path = "${config.home.homeDirectory}/.config/github/token";
        };
      };
    };

    # Ensure the age key is properly linked from the system
    home.activation.setupSopsAge = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/.config/sops/age

      # Link the age key from the system secret
      if [ -f "/run/secrets/user_age_keys/coryg" ]; then
        $DRY_RUN_CMD ln -sf /run/secrets/user_age_keys/coryg $HOME/.config/sops/age/keys.txt
      fi
    '';
  };
}
