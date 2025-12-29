{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.ddc.enable = lib.mkEnableOption "enables ddc";
  };

  config = lib.mkIf config.cg.ddc.enable {
    hardware.i2c.enable = true; # req. for ddcutil (monitor brightness control)

    # systemd.timers."hello-world" = {
    #   wantedBy = [ "timers.target" ];
    #   timerConfig = {
    #     OnCalendar = "*-*-* 4:00:00"; # *-*-* = every day, 00:00:00 time, 24-h time
    #     Unit = "hello-world.service";
    #   };
    # };
    #
    # systemd.services."hello-world" = {
    #   script = ''
    #     ddcutil setvcp 10 55 --display2
    #   '';
    #   serviceConfig = {
    #     Type = "oneshot";
    #   };
    # };
    environment.systemPackages = with pkgs; [
      ddcutil # Display management UI
      ddcui # Dispay management tool
    ];
  };
}
