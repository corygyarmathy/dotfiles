# Hyprland - Home-manager configuration
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.hyprland;

  # Startup script
  startupScript = pkgs.writeShellScriptBin "hyprland-startup" ''
    dbus-update-activation-environment --systemd HYPRLAND_INSTANCE_SIGNATURE
    dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
    ${pkgs.waybar}/bin/waybar &
    ${pkgs.dunst}/bin/dunst &
    udiskie &
  '';

  browser = "vivaldi";
  terminal = "ghostty";
  fileManager = "thunar";
  mod = "SUPER";
in {
  options.cg.home.hyprland.enable = lib.mkEnableOption "Hyprland home configuration";

  config = lib.mkIf cfg.enable {
    wayland.windowManager.hyprland = {
      enable = true;
      xwayland.enable = true;
      systemd.enable = true;

      settings = {
        exec-once = "${startupScript}/bin/hyprland-startup";

        # See https://wiki.hyprland.org/Configuring/Environment-variables/
        env = [
          "LIBVA_DRIVER_NAME,nvidia" # Required for Nvidia
          "XDG_SESSION_TYPE,wayland" # Required for Nvidia
          "GBM_BACKEND,nvidia-drm" # Required for Nvidia
          "__GLX_VENDOR_LIBRARY_NAME,nvidia" # Required for Nvidia
        ];

        cursor = {
          "no_hardware_cursors" = true; # Compatibility with Nvidia
          "inactive_timeout" = 20; # Hide cursor after x seconds of inactivity
        };

        # See https://wiki.hyprland.org/Configuring/Monitors/
        monitor = [
          ",preferred,auto,auto"
          "desc:Dell Inc. DELL U3419W 1Y9Q5T2, preferred, auto-left, 1"
          "desc:Dell Inc. DELL U2515H X48H66CQ0D1L, preferred, auto-right, 1"
        ];

        # Window rules (configured how different windows / apps behave)
        # Refer to: https://wiki.hyprland.org/Configuring/Window-Rules/
        general = {
          gaps_in = 5;
          gaps_out = 5;
          border_size = 1;
          # Please see https://wiki.hyprland.org/Configuring/Tearing/ before you turn this on
          allow_tearing = false;
          # Set to true enable resizing windows by clicking and dragging on borders and gaps
          resize_on_border = true;
          layout = "dwindle";
        };

        windowrulev2 = [
          "workspace 1, title:(.*)(- Youtube)$"
          "workspace 3, class:^(obsidian)$"
          "workspace 6, class:^(discord)$"
          "workspace 7, class:^(Zotero)$"
        ];

        decoration = {
          rounding = 16;
          blur = {
            enabled = true;
            brightness = 1.0;
            contrast = 1.0;
            noise = 0.01;
            vibrancy = 0.2;
            vibrancy_darkness = 0.5;
            passes = 4;
            size = 7;
            popups = true;
            popups_ignorealpha = 0.2;
          };
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

        input = {
          kb_layout = "us";
          # focus change on cursor move
          follow_mouse = 1;
          accel_profile = "flat";
          touchpad = {
            scroll_factor = 0.1;
            natural_scroll = true;
          };
        };

        dwindle = {
          # See https://wiki.hyprland.org/Configuring/Dwindle-Layout/ for more
          # keep floating dimentions while tiling
          pseudotile = true; # Master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
          preserve_split = true;
        };

        render.direct_scanout = true;

        misc.force_default_wallpaper = 0;

        xwayland.force_zero_scaling = true;

        debug.disable_logs = false;

        workspace = [
          "1, monitor:desc:Dell Inc. DELL U3419W 1Y9Q5T2"
          "2, monitor:desc:Dell Inc. DELL U3419W 1Y9Q5T2"
          "3, monitor:desc:Dell Inc. DELL U3419W 1Y9Q5T2"
          "4, monitor:desc:Dell Inc. DELL U3419W 1Y9Q5T2"
          "5, monitor:desc:Dell Inc. DELL U3419W 1Y9Q5T2"
          "6, monitor:desc:Dell Inc. DELL U2515H X48H66CQ0D1L"
          "7, monitor:desc:Dell Inc. DELL U2515H X48H66CQ0D1L"
          "8, monitor:desc:Dell Inc. DELL U2515H X48H66CQ0D1L"
          "9, monitor:desc:Dell Inc. DELL U2515H X48H66CQ0D1L"
          "10, monitor:desc:Dell Inc. DELL U2515H X48H66CQ0D1L"
        ];

        bindm = [
          "${mod}, mouse:272, movewindow"
          "${mod}, mouse:273, resizewindow"
          "${mod} ALT, mouse:272, resizewindow"
        ];

        bind =
          [
            "${mod}, C, killactive,"
            "${mod}, F, fullscreen,"
            "${mod}, G, togglegroup,"
            "${mod} SHIFT, N, changegroupactive, f"
            "${mod} SHIFT, P, changegroupactive, b"
            "${mod}, A, togglesplit,"
            "${mod}, V, togglefloating,"
            "${mod}, P, pseudo,"

            "${mod}, S, exec, pgrep hyprlock || hyprlock"

            "${mod}, B, exec, ${browser}"
            "${mod}, T, exec, ${terminal}"
            "${mod}, E, exec, ${fileManager}"
            "${mod}, U, exec, XDG_CURRENT_DESKTOP=gnome gnome-control-center"
            "${mod}, R, exec, rofi -show drun -show-icons"
            "${mod}, W, exec, rofi -show window -show-icons"

            "${mod}, H, movefocus, l"
            "${mod}, L, movefocus, r"
            "${mod}, K, movefocus, u"
            "${mod}, J, movefocus, d"

            "${mod}, bracketleft, workspace, m-1"
            "${mod}, bracketright, workspace, m+1"
            "${mod} SHIFT, bracketleft, focusmonitor, l"
            "${mod} SHIFT, bracketright, focusmonitor, r"
            "${mod} SHIFT ALT, bracketleft, movecurrentworkspacetomonitor, l"
            "${mod} SHIFT ALT, bracketright, movecurrentworkspacetomonitor, r"

            ", Print, exec, grimblast copy area"
          ]
          ++ (builtins.concatLists (builtins.genList (x: let
              ws = let c = (x + 1) / 10; in builtins.toString (x + 1 - (c * 10));
            in [
              "${mod}, ${ws}, workspace, ${toString (x + 1)}"
              "${mod} SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
            ])
            10));

        bindl = [
          # Monitor events
          # Disable laptop monitor in lid close, enable on lid open
          ", switch:on:Lid Switch, exec, hyprctl keyword monitor \"eDP-1, disable\""
          ", switch:off:Lid Switch, exec ,hyprctl keyword monitor \"eDP-1,3840x2400, 0x0, 1\""
          # media controls
          # FIXME: doesn't work
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
      grim # Req: wayshot
      slurp # Req: wayshot
      wl-clipboard # Enables saving screenshots to clipboard # Req: wayshot
      grimblast # Helper for screenshots within Hyprland
    ];
  };
}
