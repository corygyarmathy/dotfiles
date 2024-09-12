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
  ];

  # Enabling self-defined home-manager modules
  cg.home.nvim.enable = true;
  cg.home.waybar.enable = true; # TODO: Investigate replacing with alternative
  cg.home.rofi.enable = true;
  cg.home.starship.enable = true;
  cg.home.alacritty.enable = true;
  cg.home.spotify-player.enable = true;
  cg.home.hyprshade.enable = false;
  cg.home.hyprland.enable = false;
  cg.home.hyprlock.enable = false;
  cg.home.ergodox.enable = true;

  # NOTE: home.sessionPath doesn't currently work in Hyprland. Use environment.SessionVariables in configuration.nix instead

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

  # Configure stylix in home manager (for RICEing)
  stylix = {
    targets = {
      # Disabling as I have a custom configuration
      waybar.enable = false;
      vim.enable = false; # Covers both vim and nvim
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
    lsd # Next-gen 'ls' command
    # (pkgs.callPackage ../../pkgs/nixos-pkgs/bootdevcli { }) # Custom building package # Used for boot.dev course # TODO: figure out how to do custom packages better?
    unixtools.xxd # xxd creates a hex dump of a given file or standard input.
    pandoc # Conversion between documentation formats
    wine-wayland
    wineWowPackages.waylandFull
    winetricks

    # Entertainment
    discord
    zotero
    steam
    calibre
    gargoyle # Used for running games

    # RICE / aesthetics
    rose-pine-gtk-theme
    rose-pine-icon-theme
    rose-pine-cursor

    # Drivers
    gutenprint # Drivers for many different printers from many different vendors.
  ];

  # Enable home-manager
  programs.home-manager.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.05";
}
