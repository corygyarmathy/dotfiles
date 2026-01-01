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

      # Set password policies
      pam.services.passwd.rules.password.pwquality = {
        control = "required";
        modulePath = "${pkgs.libpwquality}/lib/security/pam_pwquality.so";
        settings = {
          retry = "3";
          minlen = "12";
          difok = "3";
          ucredit = "-1";
          lcredit = "-1";
          dcredit = "-1";
          ocredit = "-1";
          maxrepeat = "3";
        };
      };

      # Enable polkit for privilege escalation prompts
      polkit.enable = true;
    };

    # Automatic screen lock on idle (handled by hyprlock in your case)
    # This is a backup via logind
    services.logind = {
      lidSwitch = "suspend";
      lidSwitchExternalPower = "lock";
      extraConfig = ''
        IdleAction=lock
        IdleActionSec=600
      '';
    };
  };
}
