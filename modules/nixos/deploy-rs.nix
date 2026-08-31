# modules/nixos/deploy-rs.nix
# The deploy user that `deploy-rs` connects as (items 6 and 10 of the hardening
# plan).
#
# deploy-rs connects to a host as this user over SSH, then escalates to root
# with `sudo` to activate the system profile. Everything else this module does
# is make that account real on a host that otherwise only has one human:
#
#   - a non-interactive account whose *only* sudo is the deployment path. Item
#     10 took it out of `wheel` and gave it two NOPASSWD rules: the deploy-rs
#     profile activation binary (`/nix/store/*/activate-rs` - the store hash
#     changes every build), and the `rm` that magicRollback uses to confirm an
#     activation. `security.sudo.wheelNeedsPassword` stays on for the human;
#     this is the scoped exception that replaces the deploy password;
#   - permission to SSH in at all, by being added to `cg.ssh-hardening.allowedUsers`
#     alongside the human account `coryg` (the deploy username RE-places the
#     option's `["coryg"]` default rather than merging with it, so this has to
#     list the human too or SSH would stop accepting either of them);
#   - membership of `nix.settings.trusted-users`. This is what makes the copy
#     step of a deploy work: deploy-rs pushes unsigned, locally-built closures
#     over `ssh-ng://`, and the receiving daemon only imports paths that lack a
#     signature by a trusted key for a trusted user. Wheel used to supply this;
#     it was load-bearing, not incidental - dropping wheel without replacing it
#     would break every deploy at the copy step with "lacks a signature by a
#     trusted key";
#   - the laptop's dedicated deploy key, so `deploy homelab02` from the laptop
#     works without sharing the human admin key.
#
# Be clear-eyed about what this is and is not. It contains accidents and gives
# an audit trail; it is not a security boundary - anything that can set the
# system profile can set it to a closure containing a root shell, and
# `trusted-users` is root-equivalent in nix's own documentation. The point of
# item 10 is narrower: the weakest credential on the fleet - a hashed sudo
# password typed by a human - no longer gates the widest escalation. What
# remains is scoped to the activation path and granted to a revocable key.
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

    # The copy step (item 10's otherwise-unsung half). deploy-rs pushes
    # unsigned closures over ssh-ng, which the receiving daemon rejects for
    # anyone outside trusted-users - the exact failure `@wheel` used to mask.
    # The account is deploy-only and already root-equivalent through the
    # activation path below, so this grants no capability it does not have.
    nix.settings.trusted-users = [ cfg.username ];

    # The whole of the deploy user's sudo, scoped to the activation path
    # (item 10). deploy-rs runs every escalation as `sudo -u root`; the
    # `%wheel` rule stays password-gated and does not apply to this user.
    #
    # Both servers also run `security.sudo.execWheelOnly = true`
    # (user-security.nix), which makes the setuid sudo wrapper executable by
    # the `wheel` group only. The deploy user is deliberately not in wheel, so
    # the wrapper group is pointed at the deploy user's own group instead,
    # with the human added to it - exactly the two SSH accounts can exec sudo,
    # which is the same restricted set execWheelOnly intends. sudoedit stays
    # wheel-only, since deploy never calls it.
    security.wrappers.sudo.group = lib.mkForce cfg.username;
    users.users.coryg.extraGroups = [ cfg.username ];
    security.sudo.extraRules = [
      {
        users = [ cfg.username ];
        runAs = "root";
        commands = [
          # The profile activation binary. deploy-rs's `activate`, `wait` and
          # `revoke` are all this one binary with different subcommands; the
          # store path changes every build, hence the wildcard spanning a
          # single store component. An account that can deploy can already put
          # a closure in the store, so this is the role's own capability, not
          # a widening.
          {
            command = "/nix/store/*/activate-rs";
            options = [ "NOPASSWD" ];
          }
          # magicRollback's confirmation step: the deployer removes the canary
          # lock file, proving the new profile is healthy. The path is the
          # *resolved* one - sudo compares canonical parent directories, so a
          # store path in this rule would not match `/run/current-system/sw/bin/rm`.
          # The anchored regex confines the args to a single canary file, so a
          # second argument cannot ride along (sudoers globs match across word
          # boundaries; `*` in an argument matches `/` too).
          {
            command = "/run/current-system/sw/bin/rm ^/tmp/deploy-rs-canary-[a-z0-9]*$";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
