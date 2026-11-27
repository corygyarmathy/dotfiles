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

    # Items 8-15 of docs/plans/desktop-design.md - the missing surfaces, one
    # toggle each. The menus all go through rofi-menu (item 7).
    power-menu.enable = true;
    network-menu.enable = true;
    bluetooth-menu.enable = true;
    audio-menu.enable = true;
    clipboard.enable = true;
    keybind-sheet.enable = true;
    swayosd.enable = true;
    dnd.enable = true;
    failed-units.enable = true;
    screenshot.enable = true;

    obsidian-sync.enable = true;

    project-launcher = {
      enable = true;
      monitor = "desc:Dell Inc. DELL U3419W 1Y9Q5T2"; # ultrawide
      # directories defaults to [ "~/Projects" "~/git" ]; override if needed
    };

    # Desktop Services
    dunst.enable = true; # Notification daemon (extracted from hyprland)
    udiskie.enable = true; # USB automounting (extracted from hyprland)
    kdeconnect.enable = true; # Tray indicator (the daemon is a NixOS option)

    # Upgrade indicator in waybar
    auto-upgrade-desktop.enable = true;

    # Development
    nvim.enable = true;
    git.enable = true;
    direnv.enable = true;
    ssh.enable = true;
    psql.enable = true;
    opencode.enable = true;

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
    stateVersion = "26.05";
  };

  # ============================================================================
  # Services
  # ============================================================================
  services.mpris-proxy.enable = true; # Bluetooth media controls

  # After resume, a monitor behind the TS3 Plus dock (MST) can come back with
  # every mode rejected by i915; Hyprland gives up and leaves it enabled at
  # 0x0, black. A config reload reconfigures all outputs together and clears
  # it. The reload only runs when an output is stuck, because it also
  # re-applies the eDP-1 rule, so the lid check is repeated afterwards.
  services.hypridle.settings.general.after_sleep_cmd =
    let
      recover-monitors = pkgs.writeShellApplication {
        name = "recover-stuck-monitors";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'

          stuck() {
            hyprctl monitors -j | jq -e 'any(.[]; .disabled == false and .width == 0)' >/dev/null
          }

          # Hyprland retries a failed modeset three times, a second apart.
          for _ in 1 2; do
            sleep 5
            stuck || exit 0
            echo "recover-stuck-monitors: output stuck at 0x0, reloading Hyprland"
            hyprctl reload
            if grep -q closed /proc/acpi/button/lid/LID0/state; then
              hyprctl eval 'hl.monitor({ output = "eDP-1", disabled = true })'
            fi
          done
        '';
      };
    in
    lib.mkForce (lib.getExe recover-monitors);

  # The OneDrive client (services.onedrive in default.nix) must never mirror
  # backups/: the homelab hosts write live restic repositories there through
  # rclone, and a desktop client that is out of step re-uploads files restic
  # pruned, which corrupts the repositories (#405). Strict match anchors the
  # path at the drive root, so other directories named "backups" still sync.
  # Changing this file makes the client demand a one-off --resync.
  xdg.configFile."onedrive/config".text = ''
    skip_dir = "backups"
    skip_dir_strict_match = "true"
  '';

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
    proton-vpn
    proton-vpn-cli
    proton-pass
    protonmail-desktop
    todoist-electron

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
    thunar # File manager
    xfconf # Required for thunar
    thunar-archive-plugin # Zip / unzip plugin for Thunar
    tumbler # Req. for thunar # Generates image previews
    file-roller # Archive (.zip) manager for GNOME, required for thunar-archive-plugin
    steam-run # Allows running dynamically linked executables, made for steam
    lsd # Next-gen 'ls' command
    unixtools.xxd # xxd creates a hex dump of a given file or standard input.
    pandoc # Conversion between documentation formats
    wine-wayland
    winetricks
    faugus-launcher # GUI wine manager
    age # Generate / encrypt with age keys
    tldr # man, but with practical examples instead
    pavucontrol # Audio settings GUI # TODO: add to waybar on right click of audio module?
    jq # JSON processor
    xh # CLI for HTTP requests
    bruno
    bruno-cli
    htop
    dig # domain information groper
    small.bootdev-cli
    claude-code # TUI Claude code (agentic AI coding assistant)
    herdr

    # Entertainment
    discord
    calibre
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
