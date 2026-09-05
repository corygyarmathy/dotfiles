# KDE Connect tray indicator
{
  config,
  osConfig,
  lib,
  ...
}:
let
  cfg = config.cg.home.kdeconnect;
in
{
  options.cg.home.kdeconnect.enable = lib.mkEnableOption "KDE Connect tray indicator" // {
    description = ''
      Run `kdeconnect-indicator` as a user service. The daemon itself and its
      firewall holes come from `programs.kdeconnect.enable` on the host; this
      is only the tray icon, which has no unit of its own.
    '';
  };

  config = lib.mkIf cfg.enable {
    # A tray icon for a daemon that is not running is a worse affordance than
    # no tray icon, so say so at evaluation rather than at login.
    assertions = [
      {
        assertion = osConfig.programs.kdeconnect.enable;
        message = "cg.home.kdeconnect.enable needs programs.kdeconnect.enable on the host: the indicator is a front end for a daemon this does not start.";
      }
    ];

    # Item 4 of docs/plans/desktop-design.md. This was an `hl.exec_cmd` line in
    # configs/hypr/autostart.lua, which is the one thing in the session that
    # starts daemons outside systemd: nothing supervises it, nothing orders it
    # against graphical-session.target, and a crash is silent. Everything else
    # on this desktop is a unit, so this is one too.
    systemd.user.services.kdeconnect-indicator = {
      Unit = {
        Description = "KDE Connect tray indicator";
        After = [
          "graphical-session.target"
          "tray.target"
        ];
        PartOf = [ "graphical-session.target" ];
        # It is a StatusNotifierItem and has nowhere to draw without a host,
        # which the bar provides. udiskie's unit orders itself the same way.
        Requires = [ "tray.target" ];
      };
      Service = {
        # The host's package, not a second reference to the same default: the
        # indicator and the daemon it talks to have to be the same build.
        ExecStart = "${osConfig.programs.kdeconnect.package}/bin/kdeconnect-indicator";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
