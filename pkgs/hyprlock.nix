{
  pkgs,
  lib,
  config,
  ...
}:
{

  # TODO: investigate enabling this when the main cg.hyprlock option is enabled
  options = {
    cg.home.hyprlock.enable = lib.mkEnableOption "setting hyprlock and hypridle settings";
  };

  config = lib.mkIf config.cg.home.hyprlock.enable {
    programs.hyprlock = {
      enable = true;
      settings = {
        general = {
          grace = 5;
          hide_cursor = true;
        };

        background = [
          {
            path = "../../../wallpapers/wallpaper.jpg";
            blur_passes = 2;
            blur_size = 6;
          }
        ];

        input-field = [
          {
            size = "250, 60";
            inner_color = "rgb(91, 96, 120)";
            outer_color = "rgb(24, 25, 38)";
            font_color = "rgb(202, 211, 245)";
            placeholder_text = "";
          }
        ];

        label = [
          {
            text = "Hello";
            # color = "rgba(${hexToRgb colours.text}, 1.0)";
            # font_family = theme.fonts.default.name;
            font_size = 64;
            text_align = "center";
            halign = "center";
            valign = "center";
            position = "0, 160";
          }
          {
            text = "$TIME";
            # color = "rgba(${hexToRgb colours.subtext1}, 1.0)";
            # font_family = theme.fonts.default.name;
            font_size = 32;
            text_align = "center";
            halign = "center";
            valign = "center";
            position = "0, 75";
          }
        ];
      };
    };

    services.hypridle = {
      enable = true;
      settings = {
        general = {
          lock_cmd = "${lib.getExe pkgs.hyprlock}";
          before_sleep_cmd = "${lib.getExe pkgs.hyprlock}";
        };

        listener = [
          {
            timeout = 300; # In seconds. 300s is 5m
            on-timeout = "${lib.getExe pkgs.hyprlock}";
          }
          {
            timeout = 305;
            on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
            on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
          }
        ];
      };
    };
  };
}
