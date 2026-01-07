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
      driverPackage = "beta";
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
    auto-upgrade = {
      enable = true;
      mode = "desktop"; # or "server"
      flake = "/home/coryg/git/dotfiles";
      firmware.enable = true;
      backgroundBuild.enable = true;
      upgradeUsers = [ "coryg" ];
    };
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
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbTFXsV7R/dfJmkYO6vaEktuOp8FczetkR29d2DmQy3 coryg@xps15"
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
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelPackages = pkgs.linuxPackages_latest;
    # Note: acpi_rev_override is handled by nixos-hardware dell-xps-15-9500 module
    # WiFi power save fix (https://bugzilla.kernel.org/show_bug.cgi?id=213381)
    extraModprobeConfig = ''
      options iwlwifi power_save=1
    '';
  };

  # ============================================================================
  # Networking
  # ============================================================================
  networking.networkmanager.enable = true;
  # Use encrypted DNS
  networking.nameservers = [
    "1.1.1.1#cloudflare-dns.com"
    "1.0.0.1#cloudflare-dns.com"
  ];
  services.resolved = {
    enable = true;
    dnssec = "true";
    extraConfig = ''
      DNSOverTLS=yes
    '';
  };

  # ============================================================================
  # Localisation
  # ============================================================================
  time.timeZone = "Australia/Perth";
  i18n = {
    defaultLocale = "en_GB.UTF-8";
    extraLocaleSettings = {
      LC_ADDRESS = "en_AU.UTF-8";
      LC_IDENTIFICATION = "en_AU.UTF-8";
      LC_MEASUREMENT = "en_AU.UTF-8";
      LC_MONETARY = "en_AU.UTF-8";
      LC_NAME = "en_AU.UTF-8";
      LC_NUMERIC = "en_AU.UTF-8";
      LC_PAPER = "en_AU.UTF-8";
      LC_TELEPHONE = "en_AU.UTF-8";
      LC_TIME = "en_AU.UTF-8";
    };
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
  services.blueman.enable = false;

  # Logitech wireless devices
  hardware.logitech.wireless = {
    enable = true;
    enableGraphical = true;
  };

  # ============================================================================
  # Audio
  # ============================================================================
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ============================================================================
  # Display & Input
  # ============================================================================
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # ============================================================================
  # Services
  # ============================================================================

  # DBus
  services.dbus.enable = true;
  systemd.user.services.dbus = {
    enable = true;
    wantedBy = [ "default.target" ];
  };

  # USB auto-mounting
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # Printing
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Firmware updates
  services.fwupd.enable = true;

  # OneDrive sync
  services.onedrive.enable = true;

  # SSH server
  services.openssh.enable = true;

  # GnuPG agent
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
  services.pcscd.enable = true;

  # ============================================================================
  # Virtualisation
  # ============================================================================
  virtualisation.docker.enable = true;

  # ============================================================================
  # Programs
  # ============================================================================

  # Allow dynamically linked executables
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc
      libGL
    ];
  };

  # Gaming
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
  };
  programs.gamemode.enable = true;

  # ============================================================================
  # Environment
  # ============================================================================
  environment.sessionVariables = {
    DOTNET_ROOT = "${pkgs.dotnet-sdk_8}";
    PATH = "$PATH:$HOME/go/bin";
    GIT_EDITOR = "nvim";
    EDITOR = "nvim";
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
    blueman
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
  users.users.coryg = {
    description = "Cory Gyarmathy";
    isNormalUser = true;
    extraGroups = [
      "networkmanager"
      "wheel"
      "i2c" # For ddcutil
      "docker"
    ];
  };

  # Home-manager configuration for this user
  home-manager.users.coryg = import ./home.nix;

  # ============================================================================
  # System Version
  # ============================================================================
  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.11";
}
