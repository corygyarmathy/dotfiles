# XPS 15 - Home-manager configuration for coryg
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    # Home-manager modules
    ../../modules/home
  ];

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg.home = {
    # Shell
    starship.enable = true;
    zellij.enable = true;

    # Terminals
    alacritty.enable = false;
    ghostty.enable = true;

    # Desktop Environment
    hyprland.enable = true;
    hyprlock.enable = true;
    hyprsunset.enable = true;
    waybar = {
      enable = true;
      ddc.enable = true;
      media.enable = true;
      modifiers.enable = true;
    };

    rofi.enable = true;
    stylix.enable = true;
    brightness.enable = true;
    playerctl.enable = true;
    yazi.enable = true;

    project-launcher = {
      enable = true;
      monitor = "desc:Dell Inc. DELL U3419W 1Y9Q5T2"; # ultrawide
      # directories defaults to [ "~/Projects" "~/git" ]; override if needed
    };

    # Desktop Services
    dunst.enable = true; # Notification daemon (extracted from hyprland)
    udiskie.enable = true; # USB automounting (extracted from hyprland)

    # Auto-upgrade desktop features (notifications, waybar integration)
    auto-upgrade-desktop = {
      enable = true;
      waybar.enable = true;
    };

    # Development
    nvim.enable = true;
    git.enable = true;
    direnv.enable = true;
    ssh.enable = true;

    # Media
    spotify-player.enable = false;

    # Secrets
    sops-nix.enable = true;

  };

  # ============================================================================
  # User Info
  # ============================================================================
  home = {
    username = "coryg";
    homeDirectory = "/home/coryg";
    stateVersion = "24.11";
  };

  # ============================================================================
  # Services
  # ============================================================================
  services.mpris-proxy.enable = true; # Bluetooth media controls

  # ============================================================================
  # Packages
  # ============================================================================
  home.packages = with pkgs; [
    # Productivity
    vivaldi
    obsidian
    libreoffice
    google-chrome
    firefox
    protonvpn-gui
    proton-vpn-cli
    proton-pass
    protonmail-desktop
    super-productivity

    # Development
    gcc
    libgcc # GNU Compiler Collection: C, C++, Objective-C, Fortran, OpenMP for C/C++/Fortran, and Ada, and libraries for these languages # TODO: Do I need this?
    cargo # Rust package manager
    lua
    nodejs
    openssl
    bash
    go
    jdk # Java Development Kit
    python3
    hydra-check # Nixpkgs build status

    # Media
    gimp
    obs-studio
    audacity
    vlc

    # Utilities
    wget
    wireshark
    nmap
    lshw # Used to get hardware info (such as the Bus ID for the GPUs)
    xfce.thunar # File manager
    xfce.xfconf # Required for thunar
    xfce.thunar-archive-plugin # Zip / unzip plugin for Thunar
    xfce.tumbler # Req. for thunar # Generates image previews
    file-roller # Archive (.zip) manager for GNOME, required for thunar-archive-plugin
    steam-run # Allows running dynamically linked executables, made for steam
    lsd # Next-gen 'ls' command
    unixtools.xxd # xxd creates a hex dump of a given file or standard input.
    pandoc # Conversion between documentation formats
    wine-wayland
    winetricks
    bottles # GUI-wine manager
    faugus-launcher # GUI wine manager
    age # Generate / encrypt with age keys
    tldr # man, but with practical examples instead
    pavucontrol # Audio settings GUI # TODO: add to waybar on right click of audio module?
    jq # JSON processor
    httpie
    htop
    dig # domain information groper

    # Entertainment
    discord
    zotero
    texstudio # Req. for zotero?
    stable.calibre # Not building as of 2026-02-25
    gargoyle

    # Drivers
    gutenprint # Drivers for many different printers from many different vendors.
  ];

  # ============================================================================
  # Enable Home Manager
  # ============================================================================
  programs.home-manager.enable = true;

  # Reload system units when configs change
  systemd.user.startServices = "sd-switch";
}
