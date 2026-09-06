# XPS 15 9500 - Main host configuration
{
  inputs,
  config,
  lib,
  pkgs,
  pkgs-stable,
  ...
}:
{
  imports = [
    # Hardware configuration
    ./hardware.nix

    # Quirks for this exact machine, from nixos-hardware
    inputs.hardware.nixosModules.dell-xps-15-9500-nvidia

    # What it costs to be a machine in this fleet, and to be one someone sits
    # in front of. Decisions rather than options - see profiles/common.nix.
    ../../profiles/common.nix
    ../../profiles/workstation.nix

    # NixOS modules
    ../../modules/nixos
  ];

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg = {
    hyprland.enable = true;
    nvidia = {
      enable = true;
      driverPackage = "production";
    };
    stylix.enable = true;
    ddc.enable = true;
    ergodox.enable = true;
    sops-nix.enable = true;
    wireless = {
      enable = true;
      networks = [
        "Wireless"
      ];
    };
    # Follows the promoted `deploy` ref like the servers, but never switches on
    # its own - it builds in the background and waits to be clicked (ADR 0001).
    #
    # Uncommitted local config is therefore no longer picked up automatically;
    # `sudo nixos-rebuild switch --flake .#xps15` is the path for that.
    auto-upgrade = {
      enable = true;
      firmware.enable = true;
    };
    # Cheap here, and this is the machine most likely to be handed a
    # half-finished configuration - it is the one built from a working tree
    # rather than only from a revision CI has proven.
    boot-counting.enable = true;
    firewall = {
      enable = true;
      # allowedTCPPorts = [ 9000 ];
      # presets.development = true;
    };
    ssh-hardening = {
      enable = true;
      passwordAuthentication = false;
      authorizedKeys = [
        # Public host ssh keys allowed access
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGN2/Vvyb3abKAxdCYt9pxGgOho5uqtNzhpXVxGVw1gq coryg@xps15"
      ];
    };
    kernel-hardening = {
      enable = true;
      level = "desktop";
    };
    apparmor.enable = true;
    ddc = {
      location = {
        latitude = -31.98; # Your latitude
        longitude = 115.87; # Your longitude
      };
      monitors = {
        dellUltrawide.serial = "1Y9Q5T2";
        dellSecondary = {
          serial = "X48H66CQ0D1L";
          offset = -5;
        };
      };
    };
  };

  # ============================================================================
  # Boot Configuration
  # ============================================================================
  # The loader itself is in profiles/common.nix; what is here is specific to
  # this machine.
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    # Note: acpi_rev_override is handled by nixos-hardware dell-xps-15-9500 module
    # WiFi power save fix (https://bugzilla.kernel.org/show_bug.cgi?id=213381)
    extraModprobeConfig = ''
      options iwlwifi power_save=1
    '';
    # The fleet default (profiles/common.nix) keeps 10 generations, but this
    # machine's ESP is 511M and each generation's initrd is ~48M, so 10 leaves
    # /boot at ~83% used and close enough to overflow that it already did once
    # (Sep 2026). 6 keeps the same rollback depth boot-counting and
    # upgrade-verify actually reach back for while leaving comfortable headroom.
    loader.systemd-boot.configurationLimit = lib.mkForce 6;
  };

  # ============================================================================
  # Hardware Services
  # ============================================================================

  # Thermal management (XPS 15 9500 specific config)
  # Using custom thermald config for better thermal control
  services.thermald = {
    enable = true;
    configFile = ./thermald-conf.xml;
  };

  # Laptop power profiles (better battery life)
  # Just enabling the option configures sensible defaults
  # Active profile available on DBus power profile interface
  services.tlp.enable = true;

  # Thunderbolt support
  services.hardware.bolt.enable = true;

  # Touchpad (handled by nixos-hardware common-pc-laptop but we ensure it's enabled)
  services.libinput.enable = true;

  # Bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.Enable = "Source,Sink,Media,Socket";
  };
  # No blueman-applet, on purpose: the bluetooth-menu owns connect/disconnect
  # (item 9 of the desktop plan) and item 7 rejected the applet as the UI.
  # The blueman *package* is carried by the bluetooth-menu module instead of
  # the host's package list, so the pairing flow that menu should not attempt
  # stays one keystroke away in blueman-manager and the package gains the
  # purpose the "half-installed" state never had.
  services.blueman.enable = false;

  # Logitech wireless devices
  programs.solaar.enable = true;

  # ============================================================================
  # Services
  # ============================================================================
  # Audio, printing, dbus, USB auto-mounting, the GnuPG agent and nix-ld are in
  # profiles/workstation.nix. What is left here is what this machine is for.

  # Firmware updates
  services.fwupd.enable = true;

  # OneDrive sync
  services.onedrive.enable = true;

  # SSH server
  services.openssh.enable = true;

  # ============================================================================
  # Virtualisation
  # ============================================================================
  virtualisation.docker.enable = true;

  # ============================================================================
  # Programs
  # ============================================================================

  # kdeconnect - also opens firewall ports
  programs.kdeconnect.enable = true;

  # Gaming
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
  };
  programs.gamemode.enable = true;

  # ============================================================================
  # Environment
  # ============================================================================
  # The editor variables are in profiles/common.nix; these are about what this
  # machine is used for.
  environment.sessionVariables = {
    DOTNET_ROOT = "${pkgs.dotnet-sdk_8}";
    PATH = "$PATH:$HOME/go/bin";
    STEAM_EXTRA_COMPAT_TOOLS_PATHS = "\${HOME}/.steam/root/compatibilitytools.d";
  };

  # ============================================================================
  # System Packages
  # ============================================================================
  environment.systemPackages = with pkgs; [
    # System utilities
    gnome-firmware
    glib
    dconf
    xdg-utils
    libsmbios # Dell-specific BIOS utilities (fan control, etc.)
    dmidecode

    # USB utilities
    usbutils
    udiskie
    udisks

    # Gaming
    protonup-ng
  ];

  # Fonts
  fonts.packages = with pkgs; [
    font-awesome
  ];

  # ============================================================================
  # Users
  # ============================================================================
  # The account itself is in profiles/common.nix and its networkmanager group in
  # profiles/workstation.nix. These three groups exist because of the toggles
  # above, so they belong beside them.
  users.users.coryg.extraGroups = [
    "i2c" # for ddcutil (cg.ddc)
    "docker"
    "input" # for evdev keyboard monitoring (cg.ergodox)
  ];

  # Home-manager configuration for this user
  home-manager.users.coryg = import ./home.nix;

  # ============================================================================
  # System Version
  # ============================================================================
  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.11";
}
