# modules/nixos/user-security.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.user-security;
in
{
  options.cg.user-security.enable = lib.mkEnableOption "User security hardening";

  config = lib.mkIf cfg.enable {
    security = {
      # Require password for sudo
      sudo = {
        enable = true;
        wheelNeedsPassword = true;
        execWheelOnly = true; # Only wheel members can use sudo

        extraConfig = ''
          # Require password re-entry after 5 minutes
          Defaults timestamp_timeout=5

          # Log all sudo commands
          Defaults logfile="/var/log/sudo.log"

          # Show asterisks when typing password
          Defaults pwfeedback

          # Prevent sudo from preserving dangerous environment variables
          Defaults env_reset
          Defaults env_delete += "SHELLOPTS BASHOPTS CDPATH GLOBIGNORE"
        '';
      };

      # Enable polkit for privilege escalation prompts
      polkit = {
        enable = true;
        extraConfig = ''
          // Allow the unprivileged fwupd-refresh service to refresh LVFS metadata
          // without an active session (headless servers have no polkit auth agent).
          polkit.addRule(function(action, subject) {
            if ((action.id == "org.freedesktop.fwupd.refresh-remote" ||
                 action.id == "org.freedesktop.fwupd.update-metadata") &&
                subject.user == "fwupd-refresh") {
              return polkit.Result.YES;
            }
          });
        '';
      };
    };
  };
}
