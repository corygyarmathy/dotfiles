{
  lib,
  config,
  inputs,
  ...
}:
{
  imports = [
    # Import SOPS-Nix
    # inputs.sops-nix.homeManagerModules.sops
  ];

  options = {
    cg.home.sops-nix.enable = lib.mkEnableOption "enables home-manager options of sops-nix";
  };

  config = lib.mkIf config.cg.home.sops-nix.enable {
    # Sops-Nix config
    sops = {
      # This will add secrets.yml to the nix store
      # You can avoid this by adding a string to the full path instead, i.e.
      # sops.defaultSopsFile = "/root/.sops/secrets/example.yaml";
      defaultSopsFile = ../nixos/nixos-modules/nixos/sops-nix/secrets.yaml;
      age = {
        # This is using an age key that is expected to already be in the filesystem
        # This is the location of the host specific age-key for ta and will to have been extracted to this location via hosts/common/core/sops.nix on the host
        keyFile = "/home/coryg/.config/sops/age/keys.txt";
      };
      secrets = {
        # TODO: Figure out how to get this working...
        # I am putting it in the main sops config for now
        # Do I need to use the hm module?
        # "private_keys/github" = {
        #   path = "/home/coryg/.ssh/id_github2";
        # };
      };

      # This is the actual specification of the secrets.
      # Secrets with be output to /run/secrets
      # e.g. /run/ssecrets/private_keys
      # Secrets required for user creation are handled in respective ./users/$username.nix files
      # because they will be output to /run/secrets-for-users and only when the user is assigned to a host
    };
  };
}
