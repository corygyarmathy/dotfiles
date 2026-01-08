# SOPS-Nix secrets management (NixOS level)
#
# This module handles system-level secrets like:
# - SSH host keys
# - Service credentials
# - API tokens for system services
#
# Setup requirements:
# 1. Generate host age key: The key is auto-derived from SSH host key
# 2. Add host public key to secrets/.sops.yaml
# 3. Create/edit secrets: sops secrets/secrets.yaml
# 4. Enable this module and define secrets
#
# After Reinstall
#
# 1. Copy your user age key to ~/.config/sops/age/keys.txt
# 2. Get new host's age public key: sudo cat /etc/ssh/ssh_host_ed25519_key.pub | nix-shell -p ssh-to-age --run ssh-to-age
# 3. Update .sops.yaml with the new host key
# 4. Re-encrypt secrets with the new host key:
# ```bash
# sops updatekeys secrets/secrets.yaml
# ```
# 5. Commit and rebuild
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.cg.sops-nix;
in
{
  options.cg.sops-nix = {
    enable = lib.mkEnableOption "SOPS-Nix secrets management";

    defaultSecretsFile = lib.mkOption {
      type = lib.types.path;
      default = "${self}/secrets/secrets.yaml";
      description = "Default sops secrets file";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFile = cfg.defaultSecretsFile;

      # Age key configuration
      age = {
        # Use SSH host key to derive age key (no separate key file needed)
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        # Alternatively, use a dedicated age key file:
        # keyFile = "/var/lib/sops-nix/key.txt";
        # generateKey = true;
      };

      # Define system-level secrets here
      # Each secret will be available at /run/secrets/<name>
      secrets = {
        # Example: GitHub SSH key for system-wide git operations
        # "github-ssh-key" = {
        #   mode = "0600";
        #   owner = config.users.users.coryg.name;
        #   group = config.users.users.coryg.group;
        #   path = "/home/coryg/.ssh/id_github_sops";
        # };

        # Example: API token for a service
        # "some-api-token" = {
        #   mode = "0400";
        #   owner = "root";
        # };
        "users/coryg" = {
          neededForUsers = true;
        };
      };
    };

    environment.systemPackages = with pkgs; [
      sops
      age
      ssh-to-age # Convert SSH keys to age keys
    ];
  };
}
