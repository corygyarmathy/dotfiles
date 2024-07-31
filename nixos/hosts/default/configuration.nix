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
    # If you want to use modules your own flake exports (from modules/nixos):
    # outputs.nixosModules.example

    # Or modules from other flakes (such as nixos-hardware):
    # inputs.hardware.nixosModules.common-cpu-amd
    # inputs.hardware.nixosModules.common-ssd

    # You can also split up your configuration and import pieces of it here:
    # ./users.nix

    # inputs.stylix.nixosModules.stylix # Importing Stylix: used for RICEing, imports into home-manager automatically
    # Commenting out as I'm putting in Flake as experiment

    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-gpu-nvidia
    inputs.hardware.nixosModules.common-pc-laptop
    inputs.hardware.nixosModules.common-pc-laptop-ssd

    # Import your generated (nixos-generate-config) hardware configuration
    ./hardware-configuration.nix

    # Import home-manager's NixOS module
    inputs.home-manager.nixosModules.home-manager
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [
    "acpi_rev_override" # Default sugggested Dell XPS 15 config
    "nvidia-drm.modeset=1" # Used for Wayland compat.
    "nvidia-drm.fbdev=1" # Used for Wayland compat.
  ];

  # Kernel modules
  boot.kernelModules = [ "i2c-dev" ]; # req. for ddcutil (monitor brightness control)
  services.udev.extraRules = ''
    KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
  ''; # req. for ddcutil (monitor brightness control)

  # This will save you money and possibly your life!
  services.thermald.enable = lib.mkDefault true;

  # Thermald doesn't have a default config for the 9500 yet, the one in this repo
  # was generated with dptfxtract-static (https://github.com/intel/dptfxtract)
  services.thermald.configFile = lib.mkDefault thermald-conf;

  services.hardware.bolt.enable = true; # Enable and install Gnome Thunderbolt utility (Bolt)

  # WiFi speed is slow and crashes by default (https://bugzilla.kernel.org/show_bug.cgi?id=213381)
  # disable_11ax - required until ax driver support is fixed (disable_11ax=1)
  # power_save - works well on this card
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=1
  '';

  ## Nvidiaa Drivers / GPU ##

  # Enable OpenGL
  hardware.opengl = {
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
    powerManagement.finegrained = false;

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
    package = config.boot.kernelPackages.nvidiaPackages.stable;
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

  # TODO: Set your hostname
  networking.hostName = "nixos";

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
  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  # services.xserver.displayManager.gdm.enable = true;
  # services.xserver.desktopManager.gnome.enable = true;

  # Enable Wayland
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
    displayManager.gdm = {
      enable = true;
      wayland = true;
    };
  };

  # Enable the Hyprland compositor
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
    # Ensures you're using the most up-to-date package (probably another way of doing this)
    package = inputs.hyprland.packages."${pkgs.system}".hyprland;
  };

  # Required for Hyprland on Nvidia
  environment.sessionVariables = {
    # If your cusor becomes inviseble
    WLR_NO_HARDWARE_CURSORS = "1";
    # Hint Electron apps to use Wayland
    NIXOS_OZONE_WL = "1";

    # Required variables for Nvidea
    LIBVA_DRIVER_NAME = "nvidia";
    XDG_SESSION_TYPE = "wayland";
    GBM_BACKEND = "nvidia-drm";
    # Required for .NET (using .NET SDK 8)
    DOTNET_ROOT = "${pkgs.dotnet-sdk_8}";
  };

  # Required for Wayland
  security.polkit.enable = true;

  # Handles desktop windows interactions between each other (e.g. screen sharing)
  # xdg.portal.enable = true;
  # xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Required for USB storage devices to auto-mount
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  stylix = {
    enable = true;
    autoEnable = true; # Enables stylix themes for all applications
    base16Scheme = "${pkgs.base16-schemes}/share/themes/rose-pine.yaml";
    polarity = "dark"; # "light" or "either" - sets light or dark mode
    image = ../../wallpapers/wallpaper.jpg; # Sets wallpaper, ""s are not required for path

    cursor = {
      package = pkgs.rose-pine-cursor;
      name = "BreezeX-RosePine-Linux";
      size = 24;
    };

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

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
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

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # TODO: Configure your system-wide user settings (groups, etc), add more users as needed.
  users.users = {
    coryg = {
      # TODO: You can set an initial password for your user.
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

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    gnome-firmware
    inputs.home-manager.packages.${pkgs.system}.default # Install home-manager automatically
    # nvidia-utils # Nvidea userspace graphics drivers
    xdg-desktop-portal-hyprland # Req. for Hyprland # xdg-desktop-portal backend for Hyprland
    xdg-desktop-portal-gtk # Req. for Hyprland # filepicker for XDPH
    egl-wayland # Required in order to enable compatibility between the EGL API and the Wayland protocol
    qt5.qtwayland # Required for Wayland / Hyprland
    qt6.qtwayland # Required for Wayland / Hyprland

    base16-schemes # Imports colours schemes. Used for RICEing with Stylix.
    bibata-cursors # Imports cursors
    glib # Core object system for GNOME
    dconf
    xdg-utils # A set of command line tools that assist applications with a variety of desktop integration tasks
    gtk3

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

  home-manager = {
    extraSpecialArgs = {
      inherit inputs outputs;
    };
    users = {
      # Import your home-manager configuration
      coryg = import ../../home-manager/home.nix;
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "23.05";
}
