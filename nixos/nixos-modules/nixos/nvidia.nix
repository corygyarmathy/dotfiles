{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
{
  imports = [
    inputs.hardware.nixosModules.common-gpu-nvidia
  ];
  options = {
    cg.nvidia.enable = lib.mkEnableOption "enables nvidia";
  };

  config = lib.mkIf config.cg.nvidia.enable {
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
      # NOTE: when true, seemed to crash display manager when resuming from sleep
      # The display manager also crashes when this is false - trying to re-enable to see if it helps at all
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
  };
}
