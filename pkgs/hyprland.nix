# hyprland.nixhypr

{
  pkgs,
  lib,
  config,
  ...
}:
let
  # Startup script for Wayland / Hyprland
  # FIXME: only run these packages if they're installed??
  startupScript = pkgs.pkgs.writeShellScriptBin "start" ''
    ${pkgs.waybar}/bin/waybar &
    ${pkgs.dunst}/bin/dunst init &
    udiskie &
    dbus-update-activation-environment --systemd HYPRLAND_INSTANCE_SIGNATURE
    hyprshade auto
  '';
  # dbus-update required for Hyprshade
  # Removed from above: ${pkgs.swww}/bin/swww init &  ${pkgs.swww}/bin/swww img ${/home/coryg/git/nixos-config/home-manager/wallpaper.jpg} &
  browser = "firefox";
  terminal = "alacritty";
  fileManager = "thunar";
  mod = "SUPER";
in
{

  options = {
    cg.home.hyprland.enable = lib.mkEnableOption "enables hyprland";
  };

  config = lib.mkIf config.cg.home.hyprland.enable {
    # NOTE: home.sessionPath doesn't currently work in Hyprland. Use environment.SessionVariables in configuration.nix instead

    # Configure Wayland / hyrland
    wayland.windowManager.hyprland = {
      enable = true;
      xwayland.enable = true;
      systemd.enable = true;

      plugins = [
        # inputs.hyprland-plugins.packages."${pkgs.system}".borders-plus-plus
      ];

      settings = {
        # TODO: Revist how this is done, feels like a janky implementation
        exec-once = ''${startupScript}/bin/start'';

        # See https://wiki.hyprland.org/Configuring/Environment-variables/
        env = [
          "LIBVA_DRIVER_NAME,nvidia" # Required for Nvidia
          "XDG_SESSION_TYPE,wayland" # Required for Nvidia
          "GBM_BACKEND,nvidia-drm" # Required for Nvidia
          "__GLX_VENDOR_LIBRARY_NAME,nvidia" # Required for Nvidia
        ];

        cursor = {
          "no_hardware_cursors" = true; # Compatibility with Nvidia
        };

        # See https://wiki.hyprland.org/Configuring/Monitors/
        monitor = ",preferred,auto,auto";

        # Window rules (configured how different windows / apps behave)
        # Refer to: https://wiki.hyprland.org/Configuring/Window-Rules/
        general = {
          gaps_in = 5;
          gaps_out = 5;
          border_size = 1;
          # "col.active_border" = "rgba(88888888)";
          # "col.inactive_border" = "rgba(00000088)";
          # Please see https://wiki.hyprland.org/Configuring/Tearing/ before you turn this on
          allow_tearing = false;
          # Set to true enable resizing windows by clicking and dragging on borders and gaps
          resize_on_border = true;

          layout = "dwindle";
        };

        decoration = {
          rounding = 16;
          blur = {
            enabled = true;
            brightness = 1.0;
            contrast = 1.0;
            noise = 1.0e-2;

            vibrancy = 0.2;
            vibrancy_darkness = 0.5;

            passes = 4;
            size = 7;

            popups = true;
            popups_ignorealpha = 0.2;
          };

          drop_shadow = true;
          shadow_ignore_window = true;
          shadow_offset = "0 15";
          shadow_range = 100;
          shadow_render_power = 2;
          shadow_scale = 0.97;
          # "col.shadow" = "rgba(00000055)";
        };

        animations = {
          # see https://wiki.hyprland.org/Configuring/Animations/ for more
          enabled = true;
          animation = [
            "border, 1, 2, default"
            "fade, 1, 4, default"
            "windows, 1, 3, default, popin 80%"
            "workspaces, 1, 2, default, slide"
          ];
        };

        group = {
          groupbar = {
            font_size = 10;
            gradients = false;
            # text_color = "rgb(${c.primary})";
          };

          # "col.border_active" = "rgba(${c.primary_container}88);";
          # "col.border_inactive" = "rgba(${c.on_primary_container}88)";
        };

        input = {
          kb_layout = "us";

          # focus change on cursor move
          follow_mouse = 1;

          accel_profile = "flat";
          touchpad.scroll_factor = 0.1;
          touchpad.natural_scroll = true;
        };

        dwindle = {
          # See https://wiki.hyprland.org/Configuring/Dwindle-Layout/ for more
          # keep floating dimentions while tiling
          pseudotile = true; # Master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
          preserve_split = true;
        };

        render = {
          # we do, in fact, want direct scanout
          direct_scanout = true;

        };
        misc = {
          # disable auto polling for config file changes
          # disable_autoreload = true;

          force_default_wallpaper = 0; # Set to 0 or 1 to disable the anime mascot wallpapers

          # disable dragging animation
          animate_mouse_windowdragging = false;

          # enable variable refresh rate (effective depending on hardware)
          # vrr = 1;

        };

        # touchpad gestures
        gestures = {
          workspace_swipe = true;
          workspace_swipe_forever = true;
        };

        xwayland.force_zero_scaling = true; # Fixes blurry xwayland apps

        debug.disable_logs = false;
        # mouse movements
        bindm = [
          "${mod}, mouse:272, movewindow"
          "${mod}, mouse:273, resizewindow"
          "${mod} ALT, mouse:272, resizewindow"
        ];

        bind =
          [
            # compositor commands
            # Home row (Colemak-dhm): Left: arstg Right: mneio
            # "${mod} SHIFT, E, exec, pkill Hyprland"
            "${mod}, C, killactive," # [C]lose
            "${mod}, F, fullscreen," # [F]ullscreen
            "${mod}, G, togglegroup," # Toggle [G]roup
            "${mod} SHIFT, N, changegroupactive, f"
            "${mod} SHIFT, P, changegroupactive, b"
            "${mod}, A, togglesplit," # Re-[A]rrange windows ??
            "${mod}, V, togglefloating,"
            "${mod}, P, pseudo," # [P]seudo
            "${mod} ALT, ,resizeactive,"

            # Utility
            "${mod}, S, exec, pgrep hyprlock || hyprlock" # [S]ecure machine (lock -but L was taken)

            # Open Applications
            "${mod}, B, exec, ${browser}" # Open [B]rowser
            "${mod}, T, exec, ${terminal}" # Open [T]erminal
            "${mod}, E, exec, ${fileManager}" # Open [T]erminal
            "${mod}, U, exec, XDG_CURRENT_DESKTOP=gnome gnome-control-center" # open settings, FIXME: Doesn't work
            "${mod}, R, exec, rofi -show drun -show-icons" # Open Rofi Application [R]unner
            "${mod}, W, exec, rofi -show window -show-icons" # Open Rofi [W]indow switcher

            # move focus (hjkl)
            "${mod}, H, movefocus, l" # Left
            "${mod}, L, movefocus, r" # Right
            "${mod}, K, movefocus, u" # Up
            "${mod}, J, movefocus, d" # Down

            # cycle workspaces
            "${mod}, bracketleft, workspace, m-1"
            "${mod}, bracketright, workspace, m+1"

            # cycle monitors
            "${mod} SHIFT, bracketleft, focusmonitor, l"
            "${mod} SHIFT, bracketright, focusmonitor, r"

            # send focused workspace to left/right monitors
            "${mod} SHIFT ALT, bracketleft, movecurrentworkspacetomonitor, l"
            "${mod} SHIFT ALT, bracketright, movecurrentworkspacetomonitor, r"

            # Take screenshot of all sceens
            ", Print, exec, grimblast copy area"

            # TODO: add screenshot key bindings
          ]
          ++ (
            # workspaces
            # binds ${mod} + [shift +] {1..10} to [move to] workspace {1..10}
            builtins.concatLists (
              builtins.genList (
                x:
                let
                  ws =
                    let
                      c = (x + 1) / 10;
                    in
                    builtins.toString (x + 1 - (c * 10));
                in
                [
                  "${mod}, ${ws}, workspace, ${toString (x + 1)}"
                  "${mod} SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
                ]
              ) 10
            )
          );

        bindl = [
          # Monitor events
          ", switch:on:Lid Switch, exec, hyprctl keyword monitor \"eDP-1, disable\""
          ", switch:off:Lid Switch, exec ,hyprctl keyword monitor \"eDP-1,3840x2400, 0x0, 1\""

          # media controls
          ", XF86AudioPlay, exec, playerctl play-pause"
          ", XF86AudioPrev, exec, playerctl previous"
          ", XF86AudioNext, exec, playerctl next"

          # volume
          ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ];

        bindle = [
          # volume
          ", XF86AudioRaiseVolume, exec, wpctl set-volume -l '1.0' @DEFAULT_AUDIO_SINK@ 6%+"
          ", XF86AudioLowerVolume, exec, wpctl set-volume -l '1.0' @DEFAULT_AUDIO_SINK@ 6%-"

          # backlight
          ", XF86MonBrightnessUp, exec, brillo -q -u 300000 -A 5"
          ", XF86MonBrightnessDown, exec, brillo -q -u 300000 -U 5"
        ];
      };
    };

    home.packages = with pkgs; [
      dunst # Notification daemon
      libnotify # Required for Dunst
      swww # Wallpaper daemon
      # TODO: Figure out these screenshot things:
      # I can do grimblast copy area currently - do I need everything else?
      # wayshot # CLI screenshot utility
      grim # Req: wayshot
      slurp # Req: wayshot
      wl-clipboard # Enables saving screenshots to clipboard # Req: wayshot

      grimblast # Helper for screenshots within Hyprland
    ];
  };
}
