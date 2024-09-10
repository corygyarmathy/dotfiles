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
    programs.hyprlock.settings = {
      background = [
        {
          path = "../../../wallpapers/wallpaper.jpg";
          blur_passes = 2; # 0 disables blurring
          blur_size = 7;
          noise = 1.17e-2;
          contrast = 0.8916;
          brightness = 0.8172;
          vibrancy = 0.1696;
          vibrancy_darkness = 0.0;
        }
      ];

      input-field = [
        {
          size = "200, 50";
          position = "0, -80";
          monitor = "";
          dots_center = true;
          fade_on_empty = false;
          font_color = "rgb(202, 211, 245)";
          inner_color = "rgb(91, 96, 120)";
          outer_color = "rgb(24, 25, 38)";
          outline_thickness = 5;
          # placeholder_text = "'\'<span foreground=\"##cad3f5">Password...</span>'\'";
          shadow_passes = 2;
        }
      ];
    };
  };
}
