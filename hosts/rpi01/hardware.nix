# Raspberry Pi 4 Model B with an Adafruit RGB Matrix Bonnet on the GPIO header.
#
# Board support comes from nvmd/nixos-raspberrypi rather than nixpkgs'
# generic aarch64 SD image: the matrix library (hzeller/rpi-rgb-led-matrix)
# drives the BCM2711's GPIO and PWM registers directly and is developed against
# the vendor kernel and device tree, and this is what ships them - prebuilt, from
# nixos-raspberrypi.cachix.org, which `trusted-nix-caches` adds below.
{ nixos-raspberrypi, lib, ... }:
{
  imports = [
    # What nixos-raspberrypi's own `lib.nixosSystem` would add, taken as
    # modules so this host is still built by the flake's `mkHost` like the
    # others: `pkgs.rpi` and the kernel/firmware/bootloader overlays.
    nixos-raspberrypi.nixosModules.nixpkgs-rpi
    nixos-raspberrypi.lib.inject-overlays
    nixos-raspberrypi.nixosModules.trusted-nix-caches

    # Vendor kernel, firmware, and the Pi bootloader (U-Boot by default on a
    # Pi 4).
    nixos-raspberrypi.nixosModules.raspberry-pi-4.base

    # The SD card layout, kept permanently rather than only for the first
    # flash: it is what declares the root and firmware filesystems this host
    # runs from, and `system.build.sdImage` is how the card is made.
    nixos-raspberrypi.nixosModules.sd-image
  ];

  # The matrix library refuses to start while the onboard sound driver holds
  # the PWM block it uses for pulse timing. Off at the firmware, and the module
  # kept from loading in case anything asks for it anyway. `value` is not a
  # default upstream, hence mkForce.
  hardware.raspberry-pi.config.all.base-dt-params.audio.value = lib.mkForce "off";
  boot.blacklistedKernelModules = [ "snd_bcm2835" ];

  # The SD image pulls in nixpkgs' profiles/base.nix, which enables ZFS. Nothing
  # here uses it, and it would be an out-of-tree module compiled against the
  # vendor kernel - which no cache has prebuilt.
  boot.supportedFilesystems.zfs = lib.mkForce false;
}
