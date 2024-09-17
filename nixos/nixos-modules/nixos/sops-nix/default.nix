{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
{

  imports = [
    # Import SOPS-Nix
    # inputs.sops-nix.nixosModules.sops
  ];

  options = {
    cg.sops-nix.enable = lib.mkEnableOption "enables sops-nix";
  };

  config = lib.mkIf config.cg.sops-nix.enable {
    # sops-nix config

    sops = {
      # This will add secrets.yml to the nix store
      # You can avoid this by adding a string to the full path instead, i.e.
      # sops.defaultSopsFile = "/root/.sops/secrets/example.yaml";
      defaultSopsFile = ./secrets.yaml;
      age = {
        # Automatically import SSH keys as age keys
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        # This is using an age key that is expected to already be in the filesystem
        keyFile = "/var/lib/sops-nix/key.txt";
        # Generate a new key if the key specified above does not exist
        generateKey = true;

      };

      # This is the actual specification of the secrets.
      # Secrets with be output to /run/secrets
      # e.g. /run/ssecrets/private_keys
      # Secrets required for user creation are handled in respective ./users/$username.nix files
      # because they will be output to /run/secrets-for-users and only when the user is assigned to a host
      secrets = {
        # For home-manager a separate age key is used to decrypt secrets and must be placed onto the host. This is because
        # the user doesn't have read permission for the ssh service private key. However, we can bootstrap the age key from
        # the secrets decrypted by the host key, which allows home-manager secrets to work without manually copying over
        # the age key.
        # These age keys are are unique for the user on each host and are generated on their own (i.e. they are not derived
        # from an ssh key).
        # TODO: programatically set username (replace 'coryg')
        "user_age_keys/coryg/${config.networking.hostName}" = {
          owner = config.users.users.coryg.name;
          inherit (config.users.users.coryg) group;
          # We need to ensure the entire directory structure is that of the user...
          path = "/home/coryg/.config/sops/age/keys.txt";
        };
        # TODO: investigate if this is the correct method
        # TODO: investigate if the key is stored securely on the system
        # - Research best practices for ssh keys
        # TODO: figure out how to perform the 'ssh-add key_file' command programatically
        "private_keys/github" = {
          mode = "0400";
          owner = config.users.users.coryg.name;
          inherit (config.users.users.coryg) group;
          path = "/home/coryg/.ssh/id_github";
        };
      };
    };

    environment.systemPackages = with pkgs; [
      sops
    ];
  };
}
