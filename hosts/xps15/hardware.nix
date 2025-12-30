# XPS 15 9500 - Hardware configuration
# Auto-generated with some manual additions for hibernation support.
# Do not modify unless hardware changes!
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ============================================================================
  # Kernel Modules
  # ============================================================================
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "usb_storage"
    "usbhid"
    "sd_mod"
    "rtsx_pci_sdmmc"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ============================================================================
  # Hibernation / Resume
  # ============================================================================
  # Resume device for hibernation support
  boot.resumeDevice = "/dev/disk/by-partlabel/root";
  boot.kernelParams = [
    # Swapfile offset for hibernation
    # Calculate with: filefrag -v /swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}'
    "resume_offset=2316288"
  ];

  # ============================================================================
  # Filesystems
  # ============================================================================
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/b0f7df15-dabb-4efd-8757-8eb07218ac89";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/2C78-17B9";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # ============================================================================
  # Swap
  # ============================================================================
  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024; # 16GB for hibernation support
    }
  ];

  # ============================================================================
  # Networking
  # ============================================================================
  networking.useDHCP = lib.mkDefault true;

  # ============================================================================
  # Platform
  # ============================================================================
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Intel CPU microcode updates
  # Note: Also enabled by nixos-hardware common-cpu-intel module
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
