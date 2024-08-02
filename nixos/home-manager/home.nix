# This is your home-manager configuration file
# Use this to configure your home environment (it replaces ~/.config/nixpkgs/home.nix)
{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
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
  browser = "google-chrome-stable"; # Switching as Firefox is crashing in Hyprland / Wayland when maximising YouTube videos
  terminal = "alacritty";
  fileManager = "thunar";
  mod = "SUPER";
in
{
  # You can import other home-manager modules here
  imports = [
    # Importing home-manager modules through default.nix
    # NOTE: these need to be enabled for them to apply.
    ../../pkgs
  ];

  # Enabling self-defined home-manager modules
  nvim.enable = true;
  waybar.enable = true;
  rofi.enable = true;
  starship.enable = true;
  alacritty.enable = true;
  spotify-player.enable = true;
  hyprshade.enable = true;

  nixpkgs = {
    # You can add overlays here
    overlays = [
      # Add overlays your own flake exports (from overlays and pkgs dir):
      #outputs.overlays.additions
      #outputs.overlays.modifications
      #outputs.overlays.unstable-packages

      # You can also add overlays exported from other flakes:
      # neovim-nightly-overlay.overlays.default

      # Or define it inline, for example:
      # (final: prev: {
      #   hi = final.hello.overrideAttrs (oldAttrs: {
      #     patches = [ ./change-hello-to-hi.patch ];
      #   });
      # })
    ];
    # Configure your nixpkgs instance
    config = {
      # Disable if you don't want unfree packages
      allowUnfree = true;
    };
  };

  # Configure Wayland / hyrland
  # TODO: split into separate module
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

      misc = {
        # disable auto polling for config file changes
        # disable_autoreload = true;

        force_default_wallpaper = 0; # Set to 0 or 1 to disable the anime mascot wallpapers

        # disable dragging animation
        animate_mouse_windowdragging = false;

        # enable variable refresh rate (effective depending on hardware)
        # vrr = 1;

        # we do, in fact, want direct scanout
        no_direct_scanout = false;
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

  # Configure stylix in home manager (for RICEing)
  stylix = {
    targets = {
      waybar.enable = false; # Disabling as I have a custom configuration
    };
  };

  # Devices

  # Configure firmware flashing for Ergodox keyboards
  # TODO: split into separate module
  home.file."/etc/udev/rules.d/50-zsa.rules".text = ''
      	# Rules for Oryx web flashing and live training
    	KERNEL=="hidraw*", ATTRS{idVendor}=="16c0", MODE="0664", GROUP="plugdev"
    	KERNEL=="hidraw*", ATTRS{idVendor}=="3297", MODE="0664", GROUP="plugdev"

    	# Legacy rules for live training over webusb (Not needed for firmware v21+)
    	  # Rule for all ZSA keyboards
    	  SUBSYSTEM=="usb", ATTR{idVendor}=="3297", GROUP="plugdev"
    	  # Rule for the Moonlander
    	  SUBSYSTEM=="usb", ATTR{idVendor}=="3297", ATTR{idProduct}=="1969", GROUP="plugdev"
    	  # Rule for the Ergodox EZ
    	  SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="1307", GROUP="plugdev"
    	  # Rule for the Planck EZ
    	  SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="6060", GROUP="plugdev"

    	# Wally Flashing rules for the Ergodox EZ
    	ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1"
    	ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
    	SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789ABCD]?", MODE:="0666"
    	KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", MODE:="0666"

    	# Keymapp / Wally Flashing rules for the Moonlander and Planck EZ
    	SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE:="0666", SYMLINK+="stm32_dfu"
    	# Keymapp Flashing rules for the Voyager
    	SUBSYSTEMS=="usb", ATTRS{idVendor}=="3297", MODE:="0666", SYMLINK+="ignition_dfu"
  '';

  # TODO: Set your username
  home = {
    username = "coryg";
    homeDirectory = "/home/coryg";
  };

  # Git config
  # TODO: split into separate module
  programs.git = {
    # enable = true; # Don't believe enabling here is required, package installed below
    userName = "Cory Gyarmathy";
    userEmail = "cory.gyarmathy@gmail.com";
    # git config --global credential.credentialStore gpg
  };

  # KDE Connect - syncs notifications
  services.kdeconnect = {
    enable = true;
    indicator = true;
  };

  # Add stuff for your user as you see fit:
  # programs.neovim.enable = true;
  home.packages = with pkgs; [
    # Productivity
    firefox
    obsidian
    libreoffice
    google-chrome

    # Development
    gcc
    libgcc # GNU Compiler Collection: C, C++, Objective-C, Fortran, OpenMP for C/C++/Fortran, and Ada, and libraries for these languages # TODO: Do I need this?
    python3
    cargo # Rust package manager
    lua
    luajitPackages.luarocks # Lua package manager # TODO: Do I need this?
    nodejs
    openssl
    bash

    nixfmt-rfc-style # Formatter for nix (unstable / RFC version)

    # Media
    gimp
    obs-studio
    audacity
    vlc

    # Utilities
    git
    gh # GitHub - used for authenticating with GitHub
    git-credential-manager # gcm
    dotnetCorePackages.sdk_8_0_3xx # Re: gcm # https://nixos.wiki/wiki/DotNET
    gnupg # gpg # Requirement for git-credential-manager
    pinentry-all # gnupg interface to passphrase input # Requirement for gnupg
    pass-wayland # Requirement for git-credential-manager
    lazygit # TUI for git
    wget
    wireshark
    nmap
    # ruffle # Adobe flash player emulator
    # lightspark # Adobe flash player emulator
    ddcutil # Display management UI
    ddcui # Dispay management tool
    lshw # Used to get hardware info (such as the Bus ID for the GPUs)
    tmux # Terminal multiplexer
    xfce.thunar # File manager
    xfce.xfconf # Required for thunar
    xfce.thunar-archive-plugin # Zip / unzip plugin for Thunar
    xfce.tumbler # Req. for thunar # Generates image previews
    file-roller # Archive (.zip) manager for GNOME, required for thunar-archive-plugin
    steam-run # Allows running dynamically linked executables, made for steam
    # Wayland / Hyprland
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

    # Entertainment
    discord
    zotero
    steam
    calibre

    # RICE / aesthetics
    rose-pine-gtk-theme
    rose-pine-icon-theme
    rose-pine-cursor

  ];

  # Enable home-manager
  programs.home-manager.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.05";
}
