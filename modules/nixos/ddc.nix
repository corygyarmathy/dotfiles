# DDC/CI monitor brightness control with automatic scheduling
#
# This module provides automatic brightness control for external monitors
# using DDC/CI protocol. It supports:
# - Time-based brightness scheduling with gradual transitions
# - Per-monitor brightness offsets
# - Optional sun-relative scheduling for circadian rhythm alignment
# - Manual override via CLI
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.ddc;

  # Import the package (assumes it's available in your packages overlay)
  # If not using an overlay, you can use:
  # ddcBrightnessScripts = pkgs.callPackage ../packages/ddc-brightness-scripts { };
  ddcBrightnessScripts =
    pkgs.ddc-brightness-scripts or (pkgs.callPackage ../../packages/ddc-brightness-scripts { });

  # JSON config file for the brightness daemon
  brightnessConfig = pkgs.writeText "ddc-brightness-config.json" (
    builtins.toJSON {
      inherit (cfg) baseBrightness transitionMinutes;
      periods = lib.mapAttrs (name: period: {
        inherit (period)
          time
          brightness
          sunRelative
          sunEvent
          sunOffset
          ;
      }) cfg.periods;
      monitors = lib.mapAttrs (name: monitor: {
        inherit (monitor) serial offset enabled;
      }) cfg.monitors;
      location = lib.optionalAttrs cfg.location.enable {
        latitude = cfg.location.latitude;
        longitude = cfg.location.longitude;
      };
    }
  );

in
{
  options.cg.ddc = {
    enable = lib.mkEnableOption "DDC/CI monitor brightness control";

    baseBrightness = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = "Default base brightness level (0-100)";
    };

    transitionMinutes = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Duration of brightness transitions in minutes";
    };

    updateInterval = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "How often to update brightness (in seconds)";
    };

    periods = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            time = lib.mkOption {
              type = lib.types.str;
              description = "Start time in HH:MM format (fallback if sun-relative)";
            };
            brightness = lib.mkOption {
              type = lib.types.int;
              description = "Target brightness for this period (0-100)";
            };
            sunRelative = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether this period is relative to sunrise/sunset";
            };
            sunEvent = lib.mkOption {
              type = lib.types.enum [
                "dawn"
                "sunrise"
                "sunset"
                "dusk"
              ];
              default = "sunrise";
              description = "Sun event to base timing on";
            };
            sunOffset = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Offset from sun event in minutes (can be negative)";
            };
          };
        }
      );
      default = {
        earlyMorning = {
          time = "06:00";
          brightness = 30;
        };
        day = {
          time = "09:00";
          brightness = 70;
        };
        evening = {
          time = "18:00";
          brightness = 50;
        };
        night = {
          time = "21:00";
          brightness = 25;
        };
      };
      description = "Brightness periods throughout the day";
    };

    monitors = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            serial = lib.mkOption {
              type = lib.types.str;
              description = "Monitor serial number (from ddcutil detect)";
            };
            offset = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Brightness offset from base (-100 to 100)";
            };
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to control this monitor";
            };
          };
        }
      );
      default = { };
      description = "Per-monitor configuration";
      example = lib.literalExpression ''
        {
          dellUltrawide = {
            serial = "1Y9Q5T2";
            offset = 0;
          };
          dellSecondary = {
            serial = "X48H66CQ0D1L";
            offset = -10;  # This one runs brighter
          };
        }
      '';
    };

    location = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable sun-relative brightness scheduling";
      };
      latitude = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = "Latitude for sun calculations";
      };
      longitude = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = "Longitude for sun calculations";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.i2c.enable = true;

    environment.systemPackages = [
      pkgs.ddcutil
      pkgs.ddcui
      ddcBrightnessScripts
    ];

    # User service for brightness control daemon
    systemd.user.services.ddc-brightness = {
      description = "DDC/CI Monitor Brightness Daemon";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${ddcBrightnessScripts}/bin/ddc-brightness-daemon --config ${brightnessConfig} --daemon --interval ${toString cfg.updateInterval}";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
