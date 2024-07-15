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
let # Startup script for Wayland / Hyprland
    startupScript = pkgs.pkgs.writeShellScriptBin "start" ''
      ${pkgs.waybar}/bin/waybar &
      ${pkgs.dunst}/bin/dunst init &
      dbus-update-activation-environment --systemd HYPRLAND_INSTANCE_SIGNATURE
      hyprshade auto
  
      sleep 1
  
    '';
    # dbus-update required for Hyprshade
    # Removed from above: ${pkgs.swww}/bin/swww init &  ${pkgs.swww}/bin/swww img ${/home/coryg/git/nixos-config/home-manager/wallpaper.jpg} &
    browser = "google-chrome-stable"; # Switching as Firefox is crashing in Hyprland / Wayland when maximising YouTube videos
    terminal = "alacritty";
    fileManager = "thunar";
    mod = "SUPER";
    
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
      "GBM_BACKEND,nvidia-drm"   # Required for Nvidia
      "__GLX_VENDOR_LIBRARY_NAME,nvidia" # Required for Nvidia
      "GTK_THEME,Dark-Theme" # Not sure if needed, trying to get dark mode working
      "QT_QPA_PLATFORMTHEME,qt5ct" # Again, not sure if needed
      ];
      
	cursor = {
		"no_hardware_cursors" = true; # Compatibility with Nvidea
	};

        # See https://wiki.hyprland.org/Configuring/Monitors/
	monitor= ",preferred,auto,auto";
          
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
		noise = 0.01;

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

	    xwayland.force_zero_scaling = true;

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
      ]
      ++ (
        # workspaces
        # binds ${mod} + [shift +] {1..10} to [move to] workspace {1..10}
        builtins.concatLists (builtins.genList (
            x: let
              ws = let
                c = (x + 1) / 10;
              in
                builtins.toString (x + 1 - (c * 10));
            in [
              "${mod}, ${ws}, workspace, ${toString (x + 1)}"
              "${mod} SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
            ]
          )
          10)
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
	    xfce.enable = true;
	};
};

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
  # TODO: Investigate this config mode - this works, but it's not really customised (nor do I really understand it)
programs.waybar = {
    enable = true; # Only needs to be 'enabled' once - either here or in the packages
    systemd.enable = true;
    style = ''
      ${builtins.readFile "${pkgs.waybar}/etc/xdg/waybar/style.css"}

      window#waybar {
        background: transparent;
        border-bottom: none;
      }

      #waybar {
        color: white;
      }
    '';
    settings = [{
      height = 30;
      layer = "top";
      position = "top";
      tray = { 
      	spacing = 5;
	"icon-size" = 18;

	
      };
      modules-center = [ "clock" ];
      modules-left = [ "hyprland/workspaces" ];
      modules-right = [
        "pulseaudio"
        "network"
        "cpu"
        "memory"
        "temperature"
	"battery"
        "tray"
      ];

      
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
        format-icons = [ "" "" "" "" "" ];
        format-plugged = "{capacity}% ";
        states = {
          critical = 15;
          warning = 30;
        };
      };
      clock = {
      	interval = 60;
        format-alt = "{:%Y-%m-%d}";
        tooltip-format = "{:%Y-%m-%d | %H:%M}";
      };
      cpu = {
        format = "{usage}% ";
        tooltip = true;
	color = "ffffff";
      };
      memory = { format = "{}% "; };
      network = {
        interval = 1;
        format-alt = "{ifname}: {ipaddr}/{cidr}";
        format-disconnected = "Disconnected ⚠";
        format-ethernet = "{ifname}: {ipaddr}/{cidr}   up: {bandwidthUpBits} down: {bandwidthDownBits}";
        format-linked = "{ifname} (No IP) ";
        format-wifi = "{essid} ({signalStrength}%) ";
      };
      pulseaudio = {
        format = "{volume}% {icon} {format_source}";
        format-bluetooth = "{volume}% {icon} {format_source}";
        format-bluetooth-muted = " {icon} {format_source}";
        format-icons = {
          car = "";
          default = [ "" "" "" ];
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
        format-icons = [ "" "" "" ];
      };
    }];
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
    userName  = "Cory Gyarmathy";
    userEmail = "cory.gyarmathy@gmail.com";
    # git config --global credential.credentialStore gpg
  };

  # Neovim config
  xdg.enable = true;
  # xdg.configHome = config.lib.file.mkOutOfStoreSymlink "$HOME/.config";
  xdg.configFile.nvim = {
  	source = ../nvim; # Fix this path - I gave up trying to fight it
	recursive = true;
  };

  # home.folder.".config/nvim".source = "git/nvim";
 
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
  	libgcc # GNU Compiler Collection: C, C++, Objective-C, Fortran, OpenMP for C/C++/Fortran, and Ada, and libraries for these languages 
  	
  	# Media
  	gimp
  	obs-studio
  	audacity
  	vlc
  	
  	# Utilities
  	git
	gh # GitHub - used for authenticating with GitHub
	git-credential-manager
	dotnetCorePackages.sdk_8_0_3xx # .NET # Requirement for git-credential-manager # https://nixos.wiki/wiki/DotNET
	# dotnet-runtime_8 # Requirement for git-credential-manager # https://nixos.wiki/wiki/DotNET
	gnupg # gpg # Requirement for git-credential-manager
	pinentry-all # gnupg interface to passphrase input # Requirement for gnupg
	pass-wayland # Requirement for git-credential-manager
  	wget
  	wireshark
  	nmap
  	ddcutil # Display management UI
  	ddcui # Dispay management tool
  	lshw # Used to get hardware info (such as the Bus ID for the GPUs)
  	alacritty # Terminal emulator
  	ripgrep
	xfce.thunar # File manager
	xfce.xfconf # Required for thunar
	xfce.thunar-archive-plugin # Zip / unzip plugin for Thunar
	file-roller # Archive (.zip) manager for GNOME, required for thunar-archive-plugin

	# Wayland / Hyprland
  	# waybar # Status bar for Wayland # Only needs to be enabled once
  	dunst # Notification daemon
  	libnotify # Required for Dunst
  	swww # Wallpaper daemon
  	rofi-wayland # Uplauncher for Wayland
	hyprshade # Used for 'night mode' blue light filter

  	# Entertainment
  	discord
  	zotero
  	steam
  	spotify
	calibre

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
