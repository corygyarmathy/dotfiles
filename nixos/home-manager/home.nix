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
    # outputs.homeManagerModules
    ../nixos-modules/home-manager
  ];

  # Enabling self-defined home-manager modules
  # TODO: move these into the ../nixos-modules/home-manager/ folder
  cg.home.nvim.enable = true;
  cg.home.waybar.enable = true; # TODO: Investigate replacing with alternative
  cg.home.rofi.enable = true;
  cg.home.starship.enable = true;
  cg.home.alacritty.enable = true;
  cg.home.spotify-player.enable = true;
  cg.home.hyprshade.enable = true;
  cg.home.hyprland.enable = true;
  cg.home.hyprlock.enable = true;
  cg.home.ssh.enable = true;
  cg.home.sops-nix.enable = true;
  cg.home.stylix.enable = true;
  cg.home.tmux.enable = true; # TODO: sort out tmuxinator vs. continuum (see Prime's workflow)
  cg.home.zellij.enable = false;
  #TODO: add fish config

  # NOTE: home.sessionPath doesn't currently work in Hyprland. Use environment.SessionVariables in configuration.nix instead
  # See: https://www.reddit.com/r/NixOS/comments/1ajhwxv/hyprland_homemanager_does_not_inherit/
  # You can also set these in hyprland.nix under 'env'

  services.mpris-proxy.enable = true; # Req. for bluetooth media controls

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

  # Create the user
  home = {
    username = "coryg";
    homeDirectory = "/home/coryg";
  };

  # Bash config
  programs.bash = {
    enable = true; # Req. for starship to work
  };

  # Git config
  # TODO: split into separate module
  programs.git = {
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
    go
    jdk # Java Development Kit
    nixfmt-rfc-style # Formatter for nix (unstable / RFC version)

    # Media
    gimp
    obs-studio
    audacity
    vlc

    # Utilities
    git
    gh # GitHub cli - used for authenticating with GitHub
    # TODO: is gcm still needed?
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
    lshw # Used to get hardware info (such as the Bus ID for the GPUs)
    xfce.thunar # File manager
    xfce.xfconf # Required for thunar
    xfce.thunar-archive-plugin # Zip / unzip plugin for Thunar
    xfce.tumbler # Req. for thunar # Generates image previews
    file-roller # Archive (.zip) manager for GNOME, required for thunar-archive-plugin
    steam-run # Allows running dynamically linked executables, made for steam
    lsd # Next-gen 'ls' command
    # (pkgs.callPackage ../../pkgs/nixos-pkgs/bootdevcli { }) # Custom building package # Used for boot.dev course # TODO: figure out how to do custom packages better?
    unixtools.xxd # xxd creates a hex dump of a given file or standard input.
    pandoc # Conversion between documentation formats
    wine-wayland # TODO: investigate if this is working
    wineWowPackages.waylandFull
    winetricks
    age # Generate / encrypt with age keys
    tldr # man, but with practical examples instead
    pavucontrol # Audio settings GUI # TODO: add to waybar on right click of audio module?

    # Entertainment
    discord
    zotero
    steam
    calibre
    gargoyle # Used for running games

    # Drivers
    gutenprint # Drivers for many different printers from many different vendors.
  ];

  # Enable home-manager
  programs.home-manager.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  # TL;DR: update upon OS re-install
  home.stateVersion = "23.05";
}
