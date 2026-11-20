# systemd-boot on a UEFI machine
#
# How a machine boots is a fact about its hardware, so the host turns this on
# from its hardware.nix. The x86 hosts are UEFI and boot with systemd-boot;
# rpi01 boots through the Raspberry Pi firmware and has no EFI to write to.
#
# `cg.boot-counting` writes its counters into systemd-boot entry filenames, so
# a host that enables boot counting needs this too - that module asserts it.
{ config, lib, ... }:
let
  cfg = config.cg.systemd-boot;
in
{
  options.cg.systemd-boot.enable = lib.mkEnableOption "systemd-boot on a UEFI machine";

  config = lib.mkIf cfg.enable {
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;

      # Without a limit, every `switch` - including the nightly unattended one
      # from `system.autoUpgrade` - adds one more kernel+initrd to the ESP and
      # none are ever removed. Found the hard way: homelab02's /boot hit 91%
      # used (22 generations, ZFS support inflating its initrd) and homelab01
      # was on the same trajectory at 81% (59 generations). 10 is comfortably
      # more rollback depth than boot-counting or upgrade-verify ever reach
      # back for, while leaving the ESP mostly empty again.
      #
      # Not covered by the fleet's existing `nix.gc.automatic` (flake.nix):
      # `nix-collect-garbage --delete-older-than 14d` has been running weekly on
      # both servers and freeing several GB of store garbage each time, but it
      # has never trimmed a single generation from the `system` profile itself -
      # homelab02's oldest surviving generation predates its GC policy by a week
      # with no explanation found. `configurationLimit` doesn't depend on that:
      # `nixos-rebuild switch`/`boot` prunes the system profile to this count
      # directly, every time, which is why it's the documented way to bound
      # bootloader entries rather than leaving it to GC.
      systemd-boot.configurationLimit = 10;
    };
  };
}
