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
          grace = 5; # Seconds before password required
          hide_cursor = true;
        };

        background = [
          {
            path = "screenshot";
            blur_passes = 3;
            blur_size = 6;
            noise = 1.17e-2;
            contrast = 0.8916;
            brightness = 0.8172;
          }
        ];

        input-field = [
          {
            size = "350, 50";
            outline_thickness = 2;
            dots_size = 0.3; # Scale of input-field height, 0.2 - 0.8
            dots_spacing = 0.15; # Scale of dots' absolute size, 0.0 - 1.0
            dots_center = false;
            dots_rounding = -1; # -1 default circle, -2 follow input-field rounding
            outer_color = "rgb(151515)";
            inner_color = "rgb(200, 200, 200)";
            font_color = "rgb(10, 10, 10)";
            fade_on_empty = "false";
            fade_timeout = "5000"; # Milliseconds before fade_on_empty is triggered.
            placeholder_text = "<i>Input Password...</i>"; # Text rendered in the input box when it's empty.
            hide_input = "false";
            rounding = -1; # -1 means complete rounding (circle/oval)
            check_color = "rgb(204, 136, 34)";
            fail_color = "rgb(204, 34, 34)"; # if authentication failed, changes outer_color and fail message color
            fail_text = "<i>$FAIL <b>($ATTEMPTS)</b></i>"; # can be set to empty
            fail_timeout = 500; # milliseconds before fail_text and fail_color disappears
            fail_transition = 0; # transition time in ms between normal outer_color and fail_color
            capslock_color = -1;
            numlock_color = -1;
            bothlock_color = -1; # when both locks are active. -1 means don't change outer color (same for above)
            invert_numlock = false; # change color if numlock is off
            swap_font_color = false; # see below

            position = "0, -15";
            halign = "center";
            valign = "center";
          }
        ];

        label = [
          {
            text = "Hello, $DESC";
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
          after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on"; # to avoid having to press a key twice to turn on the display.
        };

        listener = [
          {
            timeout = 150; # In seconds. 300s is 5m
            # Workaround as per: https://github.com/hyprwm/hyprlock/issues/330 - nixpkgs not yet updated
            on-timeout = "pidof  ${lib.getExe pkgs.hyprlock}|| ${lib.getExe pkgs.hyprlock}"; # Lock
          }
          {
            timeout = 300;
            on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off"; # Screen off
            on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on"; # Screen on
          }
          # FIXME: waking from suspend failing, review boot4.log
          # Fails even when Nvidia power management disabled - to investigate
          # {
          #   # TODO: make it so I can wake from suspend with external keyboard, don't have to open laptop
          #   timeout = 1800; # 30min
          #   on-timeout = "systemctl suspend"; # suspend pc
          # }
        ];
      };
    };
  };
}
