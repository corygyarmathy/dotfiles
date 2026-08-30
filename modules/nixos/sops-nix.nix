# SOPS-Nix secrets management (NixOS level)
#
# WHICH FILE A SECRET COMES FROM IS DECIDED HERE, and nowhere else. A module
# that needs a secret writes `sops.secrets."<name>" = { ... }` and says nothing
# about files; this module points that name at `secrets/<hostname>.yaml`, or at
# `secrets/shared.yaml` if the name is in `sharedSecrets` below. The mapping
# used to be eleven `sopsFile = ../../secrets/homelab.yaml` lines scattered
# across seven modules, which is how `secrets.yaml` ended up readable by a
# laptop that needed one entry out of thirty.
#
# The file layout, and the rule for what goes where, is in secrets/README.md.
# `checks/secrets.nix` enforces it: a name this fleet declares but its files do
# not carry fails `nix flake check` rather than activation at 04:00.
#
# The plaintext never reaches the Nix store. The store gets the *encrypted*
# file; sops-nix decrypts it into /run/secrets at activation, and modules
# reference `config.sops.secrets.<name>.path` or, where a config file needs the
# value inline, `config.sops.placeholder.<name>` inside a `sops.templates`
# entry.
#
# After a reinstall, a host's age key changes with its SSH host key - see
# secrets/README.md.
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

    hostSecretsFile = lib.mkOption {
      type = lib.types.path;
      default = "${self}/secrets/${config.networking.hostName}.yaml";
      defaultText = lib.literalExpression ''"''${self}/secrets/''${config.networking.hostName}.yaml"'';
      description = ''
        The file holding the secrets only this host needs. Every
        `sops.secrets.<name>` comes from here unless its name is listed in
        `sharedSecrets`.
      '';
    };

    sharedSecretsFile = lib.mkOption {
      type = lib.types.path;
      default = "${self}/secrets/shared.yaml";
      defaultText = lib.literalExpression ''"''${self}/secrets/shared.yaml"'';
      description = "The file holding the secrets named in `sharedSecrets`.";
    };

    sharedSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        Secret names that live in `sharedSecretsFile` rather than in this
        host's own file, because more than one host needs the same value.

        Every entry is a claim that two machines must agree on one value, so
        every entry carries the reason it is not host-local. Adding a name here
        widens what a host can decrypt; the default below is the whole of it.
      '';
      default = [
        # Both servers back up to the same two repositories, so both need the
        # password that opens them and the credentials that reach them.
        "backups/restic/password"
        "backups/rclone-config"
        "backups/ssh/private-key"

        # One alerting account, so that a page says the fleet is broken rather
        # than which half of it noticed.
        "monitoring/proton_smtp_token"
        "monitoring/ntfy/alerts-token"
        "monitoring/ntfy/webhook-password"

        # One Cloudflare zone. Both servers run Caddy and both answer the same
        # DNS-01 challenge with this token.
        "cloudflare/api-token"

        # A redundant pair of resolvers is only redundant if they are the same
        # resolver, admin login included.
        "adguard/admin-password"

        # Sonarr and Radarr run on homelab01; recyclarr there and the media
        # tooling on homelab02 both talk to them with these keys.
        "media-stack/sonarr/api"
        "media-stack/radarr/api"

        # One account, two machines, and `mutableUsers = false` on both - so
        # the hash has to be the same or the same password stops working when
        # you SSH to the other one.
        "users/coryg"

        # The deploy-rs user's password hash, for the same reason as coryg's:
        # the two servers must accept the same interactive sudo password when
        # the laptop deploys to either of them.
        "users/deploy"
      ];
    };
  };

  # Route each secret to its file by *name*, at the one place a name and a file
  # can be compared. This adds a second declaration of `sops.secrets` whose
  # only job is to give the submodule a name-dependent default for `sopsFile`;
  # the module system merges it with sops-nix's own declaration, so both are in
  # force. sops-nix sets its default at `mkOptionDefault` priority, and a
  # module that really does need to name a file itself still overrides both.
  options.sops.secrets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.sopsFile = lib.mkIf (lib.elem name cfg.sharedSecrets) (lib.mkDefault cfg.sharedSecretsFile);
        }
      )
    );
  };

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFile = cfg.hostSecretsFile;

      # Use the SSH host key to derive the age key, so a reinstalled host has
      # no separate key file to restore - and no key material in this repo.
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };

    environment.systemPackages = with pkgs; [
      sops
      age
      ssh-to-age # Convert SSH keys to age keys
    ];
  };
}
