# modules/nixos/boot-counting.nix
#
# systemd's Automatic Boot Assessment, so a generation that will not boot is
# abandoned in favour of an older one instead of leaving the host down.
#
# https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/
#
# The mechanism, end to end:
#
#   1. `nixos-rebuild boot`/`switch` writes the entry as
#      `nixos-<hash>+<tries>.conf` on the ESP.
#   2. systemd-boot decrements that counter before handing off to the kernel,
#      renaming the file to `+<left>-<done>`.
#   3. `systemd-bless-boot-generator` sees the counter in the EFI variables and
#      pulls `systemd-bless-boot.service` into the boot, which strips the
#      counter once `boot-complete.target` is reached.
#   4. An entry that reaches zero tries is sorted last, and systemd-boot's
#      `default nixos-*` glob then resolves to the newest entry that is not
#      bad. Both this and the `preferred` directive that pairs with it need
#      systemd-boot >= 260; the servers are on 261.
#
# What this does not cover: `boot-complete.target` requires only
# `sysinit.target`, so it means the kernel came up and the filesystems mounted,
# not that anything useful is running. A revision that boots into broken
# services blesses itself quite happily. Health-gated activation - item 3 of
# docs/plans/deployment-hardening.md - is the layer that catches that; this one
# only catches a kernel or initrd that cannot come up at all, which is the
# failure that otherwise needs someone standing in front of the machine.
#
# Only meaningful with `boot.loader.systemd-boot`; the assertion below says so
# rather than letting the setting be silently inert.
{
  config,
  lib,
  ...
}:
let
  cfg = config.cg.boot-counting;
in
{
  options.cg.boot-counting = {
    enable = lib.mkEnableOption "systemd-boot Automatic Boot Assessment";

    tries = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Boot attempts a freshly written generation is given before it is
        considered bad. Each unattended reboot spends one, so this is also the
        number of power cycles a wobbly-but-working generation survives.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.loader.systemd-boot.enable;
        message = ''
          cg.boot-counting requires boot.loader.systemd-boot.enable. Boot
          assessment is implemented by the boot loader, so it does nothing
          under GRUB or any other loader.
        '';
      }
    ];

    boot.loader.systemd-boot.bootCounting = {
      enable = true;
      inherit (cfg) tries;
    };
  };
}
