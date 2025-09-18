{
  lib,
  config,
  pkgs,
  ...
}:
{
  options = {
    cg.home.ssh.enable = lib.mkEnableOption "enables ssh";
  };

  config = lib.mkIf config.cg.home.ssh.enable {
    programs.ssh = {
      enable = true;

      # Use SSH agent for key management
      addKeysToAgent = "yes";

      matchBlocks = {
        "git" = {
          host = "gitlab.com github.com";
          user = "git";
          forwardAgent = true;
          identitiesOnly = true;
          # Reference the SOPS-managed key
          identityFile = [
            # This will be a symlink to the actual decrypted key
            "~/.ssh/id_github"
          ];
        };
      };

      # SSH multiplexing for performance
      controlMaster = "auto";
      controlPath = "~/.ssh/sockets/S.%r@%h:%p";
      controlPersist = "10m";
    };

    # Create necessary directories
    home.file.".ssh/sockets/.keep".text = "# Managed by Home Manager";

    # Create a systemd user service to link the SOPS key to .ssh
    # systemd.user.services.setup-ssh-keys = {
    #   Unit = {
    #     Description = "Setup SSH keys from SOPS";
    #     After = [ "sops-nix.service" ];
    #   };
    #   Service = {
    #     Type = "oneshot";
    #     RemainAfterExit = true;
    #     ExecStart = toString (
    #       pkgs.writeShellScript "setup-ssh-keys" ''
    #         # Wait for sops to decrypt the key
    #         while [ ! -f "/run/secrets/private_keys/github" ]; do
    #           sleep 1
    #         done
    #
    #         # Create symlink to the decrypted key
    #         ln -sf /run/secrets/private_keys/github ~/.ssh/id_github
    #
    #         # Set proper permissions on the symlink target
    #         chmod 600 /run/secrets/private_keys/github || true
    #       ''
    #     );
    #   };
    #   Install = {
    #     WantedBy = [ "default.target" ];
    #   };
    # };

    # Configure SSH agent
    services.ssh-agent.enable = true;
  };
}
