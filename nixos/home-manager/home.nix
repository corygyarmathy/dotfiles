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
  hyprland.enable = true;

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
