# waybar.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.waybar.enable = lib.mkEnableOption "enables waybar";
  };

  config = lib.mkIf config.cg.home.waybar.enable {
    # Configure waybar (status bar for wayland)
    xdg.enable = true;

    xdg.configFile."waybar/rose-pine.css" = {
      source = ./rose-pine.css; # Sourcing css file for config)
    };
    # NOTE: options for waybar - https://home-manager-options.extranix.com/?query=waybar&release=master
    # TODO: Figure out how to run the bash command 'pkill waybar' when rebuilding (as it launches it again, even if it's already running)
    # TODO: Refer to the above config options and configure it
    programs.waybar = {
      enable = true; # Only needs to be 'enabled' once - either here or in the packages
      systemd.enable = true;
      style = ''
        @import "./rose-pine.css";

        * {
          border: none;
          border-radius: 0;
          font-family: "JetBrainsMono NFM ExtraBold";
          font-weight: bold;
          font-size: 16px;
          min-height: 0;
        }

        window#waybar {
          background: rgba(21, 18, 27, 0);
          color: @text;
        }

        tooltip {
          background: @base;
          border-radius: 4px;
          border-width: 2px;
          border-style: solid;
          border-color: @overlay;
        }

        #workspaces button {
          padding: 5px;
          color: @highlightMed;
          margin-right: 5px;
        }

        #workspaces button.active {
          color: @text;
        }

        #workspaces button.focused {
          color: @subtle;
          background: @love;
          border-radius: 8px;
        }

        #workspaces button.urgent {
          color: @base;
          background: @pine;
          border-radius: 8px;
        }

        #workspaces button:hover {
          background: @highlightLow;
          color: @text;
          border-radius: 8px;
        }

        #custom-power_profile,
        #window,
        #clock,
        #battery,
        #pulseaudio,
        #network,
        #bluetooth,
        #temperature,
        #workspaces,
        #tray,
        #memory,
        #cpu,
        #disk,
        #user,
        #backlight {
          background: @base;
          opacity: 0.9;
          padding: 0px 10px;
          margin: 3px 0px;
          margin-top: 15px;
          border: 2px solid @pine;
        }

        #memory {
          color: #3e8fb0;
          border-left: 0px;
          border-right: 0px;
        }

        #disk {
          color: @iris;
          border-left: 0px;
          border-right: 0px;
        }

        #cpu {
          color: @foam;
          border-left: 0px;
          border-right: 0px;
        }

        #temperature {
          color: @gold;
          border-left: 0px;
          border-right: 0px;
        }

        #temperature.critical {
          border-left: 0px;
          border-right: 0px;
          color: @love;
        }

        #backlight {
          color: @text;
          border-radius: 0px 8px 8px 0px;
          margin-right: 20px;
        }

        #tray {
          border-radius: 8px;
          margin-left: 10px;
          margin-right: 0px;
        }

        #workspaces {
          background: @base;
          border-radius: 8px;
          margin-left: 10px;
          padding-right: 0px;
          padding-left: 5px;
        }

        #custom-power_profile {
          color: @foam;
          border-left: 0px;
          border-right: 0px;
        }

        #window {
          border-radius: 8px;
          margin-left: 60px;
          margin-right: 60px;
        }

        window#waybar.empty {
          background-color: transparent;
        }

        window#waybar.empty #window {
          padding: 0px;
          margin: 0px;
          border: 0px;
          /*  background-color: rgba(66,66,66,0.5); */ /* transparent */
          background-color: transparent;
        }

        #clock {
          color: @text;
          background: @pine;
          border-radius: 8px;
        }

        #network {
          color: @love;
          border-radius: 8px 0px 0px 8px;
          border-right: 0px;
        }

        #pulseaudio {
          color: @iris;
          border-radius: 8px;
          margin-right: 10px;
          padding-right: 5px;
        }

        #battery {
          color: @foam;
          border-radius: 0 8px 8px 0;
          margin-right: 10px;
          border-left: 0px;
        }
      '';
      settings = [
        {
          height = 30;
          layer = "top";
          position = "top";
          tray = {
            spacing = 5;
            "icon-size" = 18;
            "show-passive-items" = true;
          };
          modules-center = [ "clock" ];
          modules-left = [
            "hyprland/workspaces"
            "tray"
          ];
          modules-right = [
            "network"
            "cpu"
            "disk"
            "memory"
            "temperature"
            "battery"
            "pulseaudio"
            "backlight"
          ];

          hyprland.window = {
            format = "{title}";
            separate-outputs = true;
            max-length = 20;
          };

          disk = {
            interval = 120;
            format = "{percentage_used}% ";
          };

          # Modules configuration
          hyprland.workspaces = {
            "on-click" = "activate";
            # "active-only": false;
            "all-outputs" = true;
            "format" = "{icon}";
            "format-icons" = {
              "1" = "󰈹";
              "2" = "";
              "3" = "";
              "4" = "";
              "5" = "";
              "6" = "";
              "7" = "󰠮";
              "8" = "";
              "9" = "";
              "10" = "";
              # "","";
              # "urgent": "";
              # "active": "";
              # "default": "";
            };
          };

          battery = {
            format = "{capacity}% {icon}";
            format-alt = "{time} {icon}";
            format-charging = "{capacity}% ";
            format-icons = [
              ""
              ""
              ""
              ""
              ""
            ];
            format-plugged = "{capacity}% ";
            states = {
              critical = 15;
              warning = 30;
            };
          };
          clock = {
            interval = 60;
            format-alt = "{: %R  %d/%m}}";
            tooltip-format = "<big>{:%Y %B %d}</big>\n<tt><small>{calendar}</small></tt>";
          };
          cpu = {
            format = "{usage}% ";
            tooltip = true;
          };
          memory = {
            format = "{}% ";
          };
          network = {
            interval = 30;
            format-alt = "{ifname}: {ipaddr}/{cidr}";
            format-disconnected = "Disconnected ⚠";
            format-ethernet = "{ifname}: {ipaddr}/{cidr}   up: {bandwidthUpBits} down: {bandwidthDownBits}";
            format-linked = "{ifname} (No IP) ";
            format-wifi = "{signalStrength}% ";
          };
          pulseaudio = {
            format = "{volume}% {icon} {format_source}";
            format-bluetooth = "{volume}% {icon} {format_source}";
            format-bluetooth-muted = " {icon} {format_source}";
            format-icons = {
              car = "";
              default = [
                ""
                ""
                ""
              ];
              handsfree = "";
              headphones = "";
              headset = "";
              phone = "";
              portable = "";
            };
            format-muted = " {format_source}";
            format-source = "{volume}% ";
            format-source-muted = "";
            on-click = "pavucontrol";
          };
          temperature = {
            critical-threshold = 80;
            format = "{temperatureC}°C {icon}";
            format-icons = [
              ""
              ""
              ""
            ];
          };
        }
      ];
    };

    home.packages = with pkgs; [
      waybar # Status bar for Wayland # Only needs to be enabled once
    ];
  };
}
