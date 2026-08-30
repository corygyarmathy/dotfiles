# modules/nixos/deploy-rs.nix
# The deploy user that `deploy-rs` connects as (item 6 of the hardening plan).
#
# deploy-rs connects to a host as this user over SSH, then escalates to root
# with `sudo` to activate the system profile. Everything else this module does
# is make that account real on a host that otherwise only has one human:
#
#   - a non-interactive, wheel member; it has to elevate, so it has to be
#     allowed to;
#   - permission to SSH in at all, by being added to `cg.ssh-hardening.allowedUsers`
#     alongside the human account `coryg` (the deploy username RE-places the
#     option's `["coryg"]` default rather than merging with it, so this has to
#     list the human too or SSH would stop accepting either of them);
#   - a password hash out of SOPS, because `security.sudo.wheelNeedsPassword`
#     is on and `mutableUsers` is off - so a password can only get here from
#     the config, and sudo can only prompt for one the account actually has
#     (deploy-rs' `interactiveSudo` prompts for it);
#   - the laptop's public key, so `deploy homelab02` from the laptop works.
#
# Be clear-eyed about what this is and is not. It contains accidents and gives
# an audit trail; it is not a security boundary - anything that can set the
# system profile can set it to a closure containing a root shell, so the
# "dedicated user" buys scope, not trust.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.deploy-rs;
in
{
  options.cg.deploy-rs = {
    enable = lib.mkEnableOption "the deploy-rs deploy user";

    username = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = "The system user deploy-rs connects as.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA... deploy@laptop" ];
      description = "SSH public keys authorized to log in as the deploy user.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.username} = {
      isSystemUser = true;
      group = cfg.username;
      createHome = true;
      home = "/var/lib/${cfg.username}";
      # SSH remote commands (`nix-store --serve`) run through the user's shell;
      # the default nologin shell for system users prints "This account is
      # currently not available." and breaks `deploy`.
      shell = pkgs.bash;
      extraGroups = [ "wheel" ];
      hashedPasswordFile = config.sops.secrets."users/deploy".path;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    users.groups.${cfg.username} = { };

    # Let the deploy user in over SSH without locking out the human. The option's
    # `["coryg"]` is a default, so listing the deploy user REPLACES it unless
    # coryg is listed here too - see the header comment.
    cg.ssh-hardening.allowedUsers = [
      "coryg"
      cfg.username
    ];

    # Populated before the users are built (the same `neededForUsers` reason
    # `users/coryg` carries in profiles/server.nix).
    sops.secrets."users/deploy" = {
      neededForUsers = true;
    };
  };
}
