# Nvidia GPU configuration
# This module provides Nvidia driver setup for hybrid graphics laptops
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.nvidia;
in
{
  options.cg.nvidia = {
    enable = lib.mkEnableOption "Nvidia GPU configuration";

    # PRIME configuration for hybrid graphics
    prime = {
      intelBusId = lib.mkOption {
        type = lib.types.str;
        default = "PCI:0:2:0";
        description = "Bus ID of the Intel GPU";
      };
      nvidiaBusId = lib.mkOption {
        type = lib.types.str;
        default = "PCI:1:0:0";
        description = "Bus ID of the Nvidia GPU";
      };
    };

    # Driver version selection
    driverPackage = lib.mkOption {
      type = lib.types.enum [
        "stable"
        "beta"
        "production"
      ];
      default = "stable";
      description = "Which Nvidia driver package to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # Installs and loads the Nvidia driver
    services.xserver.videoDrivers = [ "nvidia" ];

    # Enable graphics support
    hardware.graphics = {
      enable = true;
      enable32Bit = true; # Required for 32-bit Wine/DXVK
      extraPackages = with pkgs; [
        intel-media-driver
        intel-ocl
        intel-vaapi-driver
        vulkan-loader
        pkgs.mesa
      ];
      extraPackages32 = with pkgs.pkgsi686Linux; [
        mesa
      ];
    };

    # Nvidia driver configuration
    hardware.nvidia = {
      # Use modesetting for better Wayland support
      modesetting.enable = true;

      # Power management
      powerManagement.enable = true;
      powerManagement.finegrained = true;

      # Experimenting with open drivers
      open = true;

      # Enable Nvidia settings panel
      nvidiaSettings = true;

      # Driver package selection
      package =
        if cfg.driverPackage == "beta" then
          config.boot.kernelPackages.nvidiaPackages.beta
        else if cfg.driverPackage == "production" then
          config.boot.kernelPackages.nvidiaPackages.production
        else
          config.boot.kernelPackages.nvidiaPackages.stable;

      # PRIME configuration for hybrid graphics (Intel + Nvidia)
      prime = {
        # Offload mode: Use Intel by default, Nvidia on demand
        offload = {
          enable = true;
          enableOffloadCmd = true;
        };

        # Bus IDs for both GPUs
        intelBusId = cfg.prime.intelBusId;
        nvidiaBusId = cfg.prime.nvidiaBusId;
      };
    };

    # Kernel parameters for Nvidia + Wayland
    boot.kernelParams = [
      "nvidia-drm.modeset=1"
      "nvidia-drm.fbdev=1"
      # S0ix power management for modern standby (s2idle)
      "nvidia.NVreg_EnableS0ixPowerManagement=1"
    ];

    # Environment variables for Nvidia + Wayland/Hyprland
    environment.sessionVariables = {
      # Required for Hyprland on Nvidia
      WLR_NO_HARDWARE_CURSORS = "1";
      NIXOS_OZONE_WL = "1";
      LIBVA_DRIVER_NAME = "nvidia";
      XDG_SESSION_TYPE = "wayland";
      GBM_BACKEND = "nvidia-drm";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    };
  };
}
