# Nvidia GPU configuration
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
    enable = lib.mkEnableOption "Nvidia GPU support";

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
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics.enable = true;

    hardware.nvidia = {
      modesetting.enable = true;

      prime = {
        offload = {
          enable = true;
          enableOffloadCmd = true;
        };
        intelBusId = cfg.prime.intelBusId;
        nvidiaBusId = cfg.prime.nvidiaBusId;
      };

      # Power management - can cause issues with sleep/resume
      powerManagement.enable = false;
      powerManagement.finegrained = false;

      # Use proprietary driver (open source still buggy)
      open = false;

      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.beta;
    };

    boot.kernelParams = [
      "nvidia-drm.modeset=1"
      "nvidia-drm.fbdev=1"
      "nvidia.NVreg_EnableS0ixPowerManagement=1"
    ];
  };
}
