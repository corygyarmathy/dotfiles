# Nvidia GPU configuration
# This module provides additional customization on top of nixos-hardware modules.
# For XPS 15 9500, use with: hardware.nixosModules.dell-xps-15-9500-nvidia
# which already configures PRIME offloading with correct bus IDs.
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
    enable = lib.mkEnableOption "Nvidia GPU customisation";

    # Allow overriding bus IDs for systems not using nixos-hardware modules
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
      default = "beta";
      description = "Which Nvidia driver package to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure graphics are enabled
    hardware.graphics.enable = true;

    hardware.nvidia = {
      # Use modesetting for better Wayland support
      modesetting.enable = true;

      # Power management - disabled due to issues with sleep/resume on XPS 15
      # Enable if you want to test, but be prepared for potential issues
      powerManagement.enable = false;
      powerManagement.finegrained = false;

      # Use proprietary driver (open source still has issues)
      open = false;

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
    };

    # Kernel parameters for Nvidia + Wayland
    boot.kernelParams = [
      "nvidia-drm.modeset=1"
      "nvidia-drm.fbdev=1"
      # S0ix power management for modern standby
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
