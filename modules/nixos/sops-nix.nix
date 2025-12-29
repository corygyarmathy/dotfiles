# SOPS-Nix secrets management
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.sops-nix;
in {
  options.cg.sops-nix.enable = lib.mkEnableOption "SOPS-Nix secrets management";

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFile = ../../secrets/secrets.yaml;
      age = {
        sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };

      # Define secrets here
      # secrets = {
      #   "private_keys/github" = {
      #     mode = "0600";
      #     owner = config.users.users.coryg.name;
      #     group = config.users.users.coryg.group;
      #   };
      # };
    };

    environment.systemPackages = with pkgs; [
      sops
      age
      ssh-to-age
    ];
  };
}
