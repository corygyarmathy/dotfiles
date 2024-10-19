# This is your system's configuration file.
# Use this to configure your system environment (it replaces /etc/nixos/configuration.nix)
{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
  ...
}:
let
  thermald-conf = ./thermald-conf.xml; # /home/coryg/git/nixos-config/nixos/thermald-conf.xml;
in
{
  # You can import other NixOS modules here
  imports = [
    # Importing hardware flakes
    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-pc-laptop
    inputs.hardware.nixosModules.common-pc-laptop-ssd

    # Import your generated (nixos-generate-config) hardware configuration
    ./hardware-configuration.nix

    # Import home-manager's NixOS module
    inputs.home-manager.nixosModules.home-manager

    # Import all Modules (they need to be enabled to turn on)
    # Imported via flake outputs
    outputs.nixosModules
  ];

  # Toggle modules
  cg.hyprland.enable = true;
  cg.gnome.enable = false;
  cg.nvidia.enable = true;
  cg.sops-nix.enable = true;
  cg.stylix.enable = true;
  cg.ddc.enable = true; # Montitor brightness control #TODO: add auto-brightness jobs
  cg.ergodox.enable = true;

  environment.sessionVariables = {
    DOTNET_ROOT = "${pkgs.dotnet-sdk_8}"; # Required for .NET (using .NET SDK 8)
    PATH = "$PATH:$HOME/go/bin"; # Adding locations to $PATH variable, separated by ':'
    GIT_EDITOR = "nvim"; # Set git default editor
    EDITOR = "nvim"; # set system default editor
  };

  # Boot options
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [
    "acpi_rev_override" # Default sugggested Dell XPS 15 config
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest; # Use latest Linux kernel version

  services.thermald = {
    enable = lib.mkDefault true; # monitors and controls temperature in laptops, tablets.
    # Thermald doesn't have a default config for the 9500 yet, the one in this repo
    # was generated with dptfxtract-static (https://github.com/intel/dptfxtract)
    configFile = lib.mkDefault thermald-conf;
  };

  services.hardware.bolt.enable = true; # Enable userspace daemon to enable security levels for Thunderbolt

  services.libinput.enable = true; # Enable touchpad support (enabled default in most desktopManager).

  # WiFi speed is slow and crashes by default (https://bugzilla.kernel.org/show_bug.cgi?id=213381)
  # power_save - works well on this card
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=1
  '';

  # Bluetooth
  # TODO: make separate module
  hardware.bluetooth = {
    enable = true; # enables support for Bluetooth
    powerOnBoot = true; # powers up the default Bluetooth controller on boot
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
      };
    };
  };
  services.blueman.enable = false; # Bluetooth utility / tray icon

  # Logitech unifying receiver
  # TODO: split into module
  # TODO: do I need this?
  hardware.logitech.wireless = {
    enable = true;
    enableGraphical = true;
  };

  # Enable USB devices waking from sleep
  # TODO: not yet working, to investigate further
  services.udev = {
    enable = true;
    extraRules = ''
      ACTION=="add", SUBSYSTEM=="usb", ATTR{power/wakeup}="enabled"
    '';
  };
  # Configure nix itself
  nix =
    let
      flakeInputs = lib.filterAttrs (_: lib.isType "flake") inputs;
    in
    {
      settings = {
        # Enable flakes and new 'nix' command
        experimental-features = "nix-command flakes";
        # Opinionated: disable global registry
        flake-registry = "";
        # Workaround for https://github.com/NixOS/nix/issues/9574
        nix-path = config.nix.nixPath;
        substituters = [ "https://hyprland.cachix.org" ]; # Req. for Hyprland, https://wiki.hyprland.org/Nix/Cachix/
        trusted-public-keys = [ "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=" ]; # Req. for Hyprland
      };
      # Opinionated: disable channels
      channel.enable = false;

      # Opinionated: make flake registry and nix path match flake inputs
      registry = lib.mapAttrs (_: flake: { inherit flake; }) flakeInputs;
      nixPath = lib.mapAttrsToList (n: _: "${n}=flake:${n}") flakeInputs;
    };

  home-manager.sharedModules = [
    inputs.sops-nix.homeManagerModules.sops # Imports sops-nix hm module
  ];

  # Set the system hostname
  # TODO: set hostname through variable?
  networking.hostName = "xps15";

  # Enable networking
  networking.networkmanager.enable = true;

  # Configure firewall
  networking.firewall = {
    enable = true;
    allowedTCPPortRanges = [
      {
        # KDE Connect
        from = 1714;
        to = 1764;
      }
    ];
    allowedUDPPortRanges = [
      {
        # KDE Connect
        from = 1714;
        to = 1764;
      }
    ];
  };

  # Set your time zone.
  time.timeZone = "Australia/Perth";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
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

  # Enable dynamically linked executables to run
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Add any missing dynamic libraries for unpackaged programs
    # here, NOT in environment.systemPackages
    stdenv.cc.cc
    libGL
  ];

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Required for USB storage devices to auto-mount
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;
  # Enable printer autodiscovery
  # Uses IPP Everywhere protocol: UDP port 5353
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Enable sound with pipewire.
  hardware.pulseaudio = {
    enable = false;
    package = pkgs.pulseaudioFull; # Enable extra codecs. Req. for bluetooth.
  };
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Configure your system-wide user settings (groups, etc), add more users as needed.
  users.users = {
    # TODO: set username through variable?
    # TODO: set user password through sops-nix?
    coryg = {
      # You can set an initial password for your user.
      # If you do, you can skip setting a root password by passing '--no-root-passwd' to nixos-install.
      # Be sure to change it (using passwd) after rebooting!
      # initialPassword = "correcthorsebatterystaple";
      description = "Cory Gyarmathy";
      isNormalUser = true;
      openssh.authorizedKeys.keys = [
        # TODO: Add your SSH public key(s) here, if you plan on using SSH to connect
      ];
      # The groups that the defined user is a member of
      extraGroups = [
        "networkmanager"
        "wheel"
        "i2c" # req. for ddcutil (monitor brightness control)
      ];
    };
  };

  nixpkgs = {
    # You can add overlays here
    overlays = [
      # Add overlays your own flake exports (from overlays and pkgs dir):
      outputs.overlays.additions
      outputs.overlays.modifications
      outputs.overlays.stable-packages

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

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  # Add a prefix of 'stable.' to use the nixpkgs-stable branch
  # This can be useful to downgrade a pkg, if needed
  environment.systemPackages = with pkgs; [
    inputs.home-manager.packages.${pkgs.system}.default # Install home-manager automatically

    gnome-firmware # Firmware GUI manager
    glib # Core object system for GNOME
    dconf # Req. for GNOME apps (if not running GNOME)
    xdg-utils # A set of command line tools that assist applications with a variety of desktop integration tasks
    blueman # Bluetooth utilities
    libsmbios # library to obtain BIOS information

    # USB utils - needed for auto-mounting USB storage devices
    usbutils
    udiskie
    udisks
  ];

  # Install fonts (system wide)
  fonts.packages = with pkgs; [
    nerdfonts # Fonts
    font-awesome # Fonts
  ];

  # TODO: check what this is for
  services.fwupd.enable = true;

  # This setups a SSH server. Very important if you're setting up a headless system.
  # Feel free to remove if you don't need it.
  services.openssh = {
    enable = true;
    settings = {
      # Opinionated: forbid root login through SSH.
      # PermitRootLogin = "no";
      # Opinionated: use keys only.
      # Remove if you want to SSH using passwords
      # PasswordAuthentication = false;
    };
  };

  # Monitoring as logs indicate this may be causing system crashes when resuming from sleep
  services.onedrive.enable = true; # Install and start OneDrive client

  # GnuPG config
  # TODO: check if I still need this
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    # gpg --gen-key
    # pass init <gpg-id>
  };
  services.pcscd.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  # TL;DR: update upon OS re-install
  system.stateVersion = "23.05";
}
