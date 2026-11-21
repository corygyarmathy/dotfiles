# checks/led-matrix.nix
#
# rpi01's LED matrix unit, as evaluated. Not a VM: a VM has no BCM registers
# for the library to map, and what can go wrong silently is in the generated
# configuration. Losing the drop-privilege flags leaves the display working
# while it runs as root with CAP_SYS_RAWIO, and losing the boot-time tunables
# leaves it working with more flicker; neither shows on the panels as a
# failure.
{
  lib,
  pkgs,
  self,
}:
let
  rpi01 = self.nixosConfigurations.rpi01;

  failing = eval: map (a: a.message) (builtins.filter (a: !a.assertion) eval.config.assertions);

  firesFor = eval: lib.any (lib.hasPrefix "cg.service.led-matrix: iomem=relaxed") (failing eval);

  cfg = rpi01.config;
  unit = cfg.systemd.services.led-matrix.serviceConfig;

  expectations = {
    "drops to led-matrix user" = lib.hasInfix "--led-drop-priv-user=led-matrix" unit.ExecStart;
    "drops to led-matrix group" = lib.hasInfix "--led-drop-priv-group=led-matrix" unit.ExecStart;
    "relaxes /dev/mem" = lib.elem "iomem=relaxed" cfg.boot.kernelParams;
    "isolates core 3" = lib.elem "isolcpus=3" cfg.boot.kernelParams;
    "raises the RT limit at boot" =
      cfg.boot.kernel.sysctl."kernel.sched_rt_runtime_us" or null == 990000;
    "sets core 3's governor at boot" =
      lib.any (lib.hasInfix "cpu3/cpufreq/scaling_governor") cfg.systemd.tmpfiles.rules;
    "keeps kernel tunables read-only" = unit.ProtectKernelTunables;
    "as written, the lock assertion holds" = !(firesFor rpi01);
    "with modules locked, the lock assertion fires" = firesFor (
      rpi01.extendModules {
        modules = [ { security.lockKernelModules = lib.mkForce true; } ];
      }
    );
  };

  wrong = lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations));
in
pkgs.runCommand "check-led-matrix" { inherit wrong; } ''
  if [ -n "$wrong" ]; then
    echo "FAIL: rpi01's led-matrix configuration is wrong: $wrong" >&2
    exit 1
  fi
  touch "$out"
  echo "ok: led-matrix"
''
