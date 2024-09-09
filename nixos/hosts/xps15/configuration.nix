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
    inputs.hardware.nixosModules.common-gpu-nvidia
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

  environment.sessionVariables = {
    DOTNET_ROOT = "${pkgs.dotnet-sdk_8}"; # Required for .NET (using .NET SDK 8)
    PATH = "$PATH:$HOME/go/bin"; # Adding locations to $PATH variable, separated by ':'
    GIT_EDITOR = "nvim"; # Set git default editor to nvim
  };

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [
    "acpi_rev_override" # Default sugggested Dell XPS 15 config
  ];

  hardware.i2c.enable = true; # req. for ddcutil (monitor brightness control)

  services.thermald = {
    enable = lib.mkDefault true; # monitors and controls temperature in laptops, tablets.
    # Thermald doesn't have a default config for the 9500 yet, the one in this repo
    # was generated with dptfxtract-static (https://github.com/intel/dptfxtract)
    configFile = lib.mkDefault thermald-conf;
  };

  services.hardware.bolt.enable = true; # Enable and install Gnome Thunderbolt utility (Bolt)

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # WiFi speed is slow and crashes by default (https://bugzilla.kernel.org/show_bug.cgi?id=213381)
  # power_save - works well on this card
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=1
  '';

  # Bluetooth
  hardware.bluetooth = {
    enable = true; # enables support for Bluetooth
    powerOnBoot = true; # powers up the default Bluetooth controller on boot
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
      };
    };
  };

  services.blueman.enable = true; # Bluetooth utility / tray icon

  ## Nvidia Drivers / GPU ##

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
  };

  hardware.nvidia = {

    # Modesetting is required.
    modesetting.enable = true;

    prime = {
      # Enables sync mode, dGPU will not fully go to sleep
      # sync.enable = true;

      # Bus ID of the Intel GPU.
      intelBusId = lib.mkDefault "PCI:0:2:0";

      # Bus ID of the NVIDIA GPU.
      nvidiaBusId = lib.mkDefault "PCI:1:0:0";
    };

    # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
    # Enable this if you have graphical corruption issues or application crashes after waking
    # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead 
    # of just the bare essentials.
    powerManagement.enable = true;

    # Fine-grained power management. Turns off GPU when not in use.
    # Experimental and only works on modern Nvidia GPUs (Turing or newer).
    powerManagement.finegrained = true;

    # Use the NVidia open source kernel module (not to be confused with the
    # independent third-party "nouveau" open source driver).
    # Support is limited to the Turing and later architectures. Full list of 
    # supported GPUs is at: 
    # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus 
    # Only available from driver 515.43.04+
    # Currently alpha-quality/buggy, so false is currently the recommended setting.
    open = false;

    # Enable the Nvidia settings menu,
    # accessible via `nvidia-settings`.
    nvidiaSettings = true;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.production;
  };

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
        substituters = [ "https://hyprland.cachix.org" ]; # Required for Hyprland
        trusted-public-keys = [ "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=" ]; # Required for Hyprland
      };
      # Opinionated: disable channels
      channel.enable = false;

      # Opinionated: make flake registry and nix path match flake inputs
      registry = lib.mapAttrs (_: flake: { inherit flake; }) flakeInputs;
      nixPath = lib.mapAttrsToList (n: _: "${n}=flake:${n}") flakeInputs;
    };

  # Set the system hostname
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

  # RICE settings
  stylix = {
    enable = true;
    autoEnable = true; # Enables stylix themes for all applications
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
    polarity = "dark"; # "light" or "either" - sets light or dark mode
    image = ../../../wallpapers/wallhaven-1h3u9zr.jpg; # Sets wallpaper, ""s are not required for path

    # TODO: replace with catppuccin cursor
    cursor = {
      package = pkgs.rose-pine-cursor;
      name = "BreezeX-RosePine-Linux";
      size = 28;
    };

    # TODO: Investigate new fonts
    fonts = {
      serif = {
        package = pkgs.dejavu_fonts;
        name = "DejaVu Serif";
      };

      sansSerif = {
        package = pkgs.dejavu_fonts;
        name = "DejaVu Sans";
      };

      monospace = {
        package = pkgs.dejavu_fonts;
        name = "DejaVu Sans Mono";
      };

      emoji = {
        package = pkgs.noto-fonts-emoji;
        name = "Noto Color Emoji";
      };
    };
  };

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
      # TODO: Be sure to add any other groups you need (such as networkmanager, audio, docker, etc)
      extraGroups = [
        "networkmanager"
        "wheel"
        "plugdev" # needed for firmware flashing of Ergodox keyboards
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
      outputs.overlays.unstable-packages

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
  environment.systemPackages = with pkgs; [
    inputs.home-manager.packages.${pkgs.system}.default # Install home-manager automatically

    base16-schemes # Imports colours schemes. Used for RICEing with Stylix.
    bibata-cursors # Imports cursors
    gnome-firmware # Firmware GUI manager
    glib # Core object system for GNOME
    dconf # Req. for GNOME apps (if not running GNOME)
    xdg-utils # A set of command line tools that assist applications with a variety of desktop integration tasks
    gtk3
    blueman # Bluetooth utilities

    # USB utils - needed for auto-mounting USB storage devices
    usbutils
    udiskie
    udisks
  ];

  # Install fonts (system wide)
  fonts.packages = with pkgs; [
    dejavu_fonts # Fonts
    noto-fonts-emoji # Fonts
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

  services.onedrive.enable = true; # Install and start OneDrive client

  # GnuPG config
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
  system.stateVersion = "23.05";
}
