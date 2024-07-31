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

  # FIXME: fix this script
  # Hyprscade config script - I feel like this doesn't work
  hyprshade-script = pkgs.pkgs.writeShellScriptBin "hyprshade-script" ''
     	 hyprshade install
    	 systemctl --user enable --now hyprshade.timer
    	 
    	 sleep 1 

    	 hyprshade auto
  '';
in
{
  # You can import other home-manager modules here
  imports = [
    # If you want to use modules your own flake exports (from modules/home-manager):
    # outputs.homeManagerModules.example

    # Importing Nix-Colors (for system colour settings)
    # inputs.nix-colors.homeManagerModules.default

    # You can also split up your configuration and import pieces of it here:
    # ./nvim.nix
  ];

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
  # stylix = {
  # 	targets = {
  # 	    xfce.enable = true;
  # 	};
  # };

  # TODO: Redo this using Home-Manager options
  # Configure Hyprshade profiles (blue light filter)
  home.file.".config/hypr/hyprshade.toml".text = ''
    [[shades]]
    name = "vibrance"
    default = true  # shader to use during times when there is no other shader scheduled

    [[shades]]
    name = "blue-light-filter"
    start_time = 19:00:00
    end_time = 06:00:00   # optional if you have more than one shade with start_time
  '';

  # Configure waybar (status bar for wayland)

  xdg.configFile."waybar/rose-pine.css" = {
    source = ../../pkgs/waybar/rose-pine.css; # Sourcing css file for config)
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

  # Devices

  # Configure firmware flashing for Ergodox keyboards
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
  programs.git = {
    # enable = true; # Don't believe enabling here is required, package installed below
    userName = "Cory Gyarmathy";
    userEmail = "cory.gyarmathy@gmail.com";
    # git config --global credential.credentialStore gpg
  };

  # Neovim config
  xdg.enable = true;
  # xdg.configHome = config.lib.file.mkOutOfStoreSymlink "$HOME/.config";
  xdg.configFile.nvim = {
    # TODO: check if this is the right way of sourcing - could use the standard xdg relative referencing?
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/git/dotfiles/pkgs/nvim"; # Apparently sourcing the file this way works better with nvim? Not sure.
  };

  # Bash config
  programs.bash.enable = true;
  programs.starship.enableBashIntegration = true;

  # Starship configuration (sourcing toml file for config, so I can use starship on other systems)
  xdg.configFile."starship.toml".source = ../../pkgs/starship/starship.toml;
  programs.starship.enable = true;

  # Alacritty config (terminal editor)
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        opacity = lib.mkForce 0.85;
        padding.x = 10;
      };
    };
  };

  # Spotify player settings
  programs.spotify-player = {
    settings = {
      theme = "rose-pine";
      playback_window_position = "Top";
      copy_command = {
        command = "wl-copy";
        args = [ ];
      };
      device = {
        audio_cache = true; # Caches to $APP_CACHE ($HOME/.cache/...)
        normalization = true; # Enables audio normalisation between songs
        autoplay = true; # Autoplays similar songs
      };
    };
    themes = {
      # TODO: change colours to rose-pine, currently tokyo-night
      name = "rose-pine";
      pallette = {
        background = "#191724";
        foreground = "#1f1d2e";
        black = "#414868";
        red = "#f7768e";
        green = "#9ece6a";
        yellow = "#e0af68";
        blue = "#2ac3de";
        magenta = "#bb9af7";
        cyan = "#7dcfff";
        white = "#eee8d5";
        bright_black = "#24283b";
        bright_red = "#ff4499";
        bright_green = "#73daca";
        bright_yellow = "#657b83";
        bright_blue = "#839496";
        bright_magenta = "#ff007c";
        bright_cyan = "#93a1a1";
        bright_white = "#fdf6e3";
      };
    };
  };

  # KDE Connect - syncs notifications
  services.kdeconnect = {
    enable = true;
    indicator = true;
  };

  # Themeing

  # gtk = {
  #   enable = true;
  #   theme = {
  #     name = "oomox-rose-pine";
  #     package = pkgs.rose-pine-gtk-theme;
  #   };
  #   cursorTheme = {
  #     name = "BreezeX-RoséPine";
  #     package = pkgs.rose-pine-cursor;
  #   };
  #   iconTheme = {
  #     name = "oomox-rose-pine";
  #     package = pkgs.rose-pine-icon-theme;
  #   };
  #
  #   gtk3.extraConfig = {
  #     gtk-application-prefer-dark-theme = 1;
  #   };
  #   gtk4.extraConfig = {
  #     gtk-application-prefer-dark-theme = 1;
  #   };
  #   # gtk4.extraConfig = "gtk-application-prefer-dark-theme=1";
  # };
  #
  # qt = {
  #   enable = true;
  #   platformTheme = "gtk";
  #   style = {
  #     name = "adwaita-dark";
  #   };
  # };
  #
  # xdg.portal.config = {
  #   common = {
  #     "org.freedesktop.appearance" = 1; # Prefer dark mode
  #   };
  # };

  # Add stuff for your user as you see fit:
  # programs.neovim.enable = true;
  home.packages = with pkgs; [
    # Productivity
    neovim
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
    alacritty # Terminal emulator
    tmux # Terminal multiplexer
    starship # Shell prompt
    ripgrep # Requirement for nvim
    gnumake # Requirement for nvim
    unzip # Requirement for nvim
    xclip # Requirement for nvim
    fd # Re: for nvim. # Alternative to find
    tree-sitter # Re: for nvim (tree sitter)
    nodePackages.npm # JS Node Package Manager # Requirement for nvim (mason plugin)
    xfce.thunar # File manager
    xfce.xfconf # Required for thunar
    xfce.thunar-archive-plugin # Zip / unzip plugin for Thunar
    xfce.tumbler # Req. for thunar # Generates image previews
    file-roller # Archive (.zip) manager for GNOME, required for thunar-archive-plugin
    steam-run # Allows running dynamically linked executables, made for steam
    alsa-lib # Linux Sound library # Req for spotify-player
    libdbusmenu-gtk3 # Library for passing menu structures across DBus # Req for spotify-player

    # Wayland / Hyprland
    waybar # Status bar for Wayland # Only needs to be enabled once
    dunst # Notification daemon
    libnotify # Required for Dunst
    swww # Wallpaper daemon
    rofi-wayland # Uplauncher for Wayland
    hyprshade # Used for 'night mode' blue light filter
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
    spotify-player # Spotify terminal client
    calibre

    # RICE / aesthetics
    rose-pine-gtk-theme
    rose-pine-icon-theme
    rose-pine-cursor

    # Custom Scripts
    hyprshade-script # I don't think this works... need to investigate further
  ];

  # Enable home-manager
  programs.home-manager.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.05";
}
