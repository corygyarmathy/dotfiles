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
#   3. `systemd-bless-boot-generator` pulls `systemd-bless-boot.service` into
#      the boot whenever the counter EFI variable is present; the service then
#      strips the counter once `boot-complete.target` is reached. On a legacy,
#      uncounted boot there is no variable, so the generator emits nothing and
#      the unit never runs. (Its concern in this module is the switch-restart
#      path below, not the boot path: a nixpkgs bump rewrites the packaged unit
#      and switch-to-configuration restarts it mid-session, when blessing has
#      already happened.)
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
# A nixpkgs bump rewrites every packaged systemd unit, so on each such
# `switch` the systemd-bless-boot ExecStart path changes and
# switch-to-configuration stops and restarts the unit. Re-running `bless-boot
# good` mid-session is almost always a no-op: the boot decision was already
# made at boot-complete, so the counter file was already consumed (renamed to
# the plain entry) or pruned, and the re-run fails with "Can't find boot
# counter source file for ...". That failure leaves the unit failed, and the
# switch's final scan flags any failed unit, turning a healthy activation into
# an exit-4 apply failure. The ExecStart below tolerates exactly those
# benign redundant re-blesses while genuine ESP/rename errors still fail the
# unit. The failure strings this guards against are systemd's stable,
# user-facing messages; if upstream rephrases one, the guard loses sensitivity
# and the apply failure returns - visibly, in the same journal that first
# exposed this.
#
# Only meaningful with `boot.loader.systemd-boot`; the assertion below says so
# rather than letting the setting be silently inert.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.boot-counting;

  # `good` exits 0 when the entry was counted and just got blessed, and also
  # when it was *already* blessed and the target exists ("Operation already
  # executed before"). It fails only when (a) the current boot had no counter
  # to bless, (b) the counter variable is stale or malformed, (c) the
  # counter file and its plain target are both gone - the entry was blessed
  # and then pruned, exactly what a `switch` mid-session sees - or (d) there
  # is a real ESP/rename/read problem. (a)-(c) mean the boot outcome was
  # already decided and there is nothing to say; (d) must keep failing.
  blessBootGuard = pkgs.writeShellScript "systemd-bless-boot-guard" ''
    bless="${pkgs.systemd}/lib/systemd/systemd-bless-boot"

    set +e
    out="$("$bless" good 2>&1)"
    ret=$?
    set -e

    if [ "$ret" -eq 0 ]; then
      exit 0
    fi

    # Never hide the reason: it is already on stderr from bless-boot itself;
    # echo it so the journal makes the outcome attributable.
    printf '%s\n' "$out" >&2
    case "$out" in
      *"Not booted with boot counting in effect."* | *"does not contain a counter"* | *"Can't find boot counter source file for"*)
        exit 0
        ;;
      *)
        exit "$ret"
        ;;
    esac
  '';
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

    systemd.services."systemd-bless-boot" = {
      serviceConfig.ExecStart = [
        ""
        "${blessBootGuard}"
      ];
    };
  };
}
