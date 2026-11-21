# checks/led-matrix.nix
#
# rpi01's LED matrix unit, as evaluated. Not a VM: a VM has no BCM registers
# for the library to map, and what can go wrong silently is in the generated
# configuration. Losing the drop-privilege flags leaves the display working
# while it runs as root with CAP_SYS_RAWIO, and losing the boot-time tunables
# leaves it working with more flicker; neither shows on the panels as a
# failure. Nor does a socket anyone can write to: the panels would still show
# whatever a legitimate renderer sends, and so would anything else on the host
# (ADR 0011).
#
# The renderer is here too, for the one thing about it a VM cannot show:
# rpi01's location secret is read at run time, from outside the store. The
# repo is public and the location is not, so a regression there would publish
# it through the binary cache. Its behaviour is ./matrix-display.nix.
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
  socket = cfg.systemd.sockets.led-matrix.socketConfig;
  renderer = cfg.systemd.services.matrix-display.serviceConfig;

  # A stand-in library, to show the sink follows `package` rather than
  # whatever pkgs.rpi-rgb-led-matrix happens to be.
  patched = rpi01.extendModules {
    modules = [
      (
        { pkgs, ... }:
        {
          cg.service.led-matrix.package = pkgs.rpi-rgb-led-matrix.overrideAttrs { pname = "patched"; };
        }
      )
    ];
  };
  patchedCfg = patched.config.cg.service.led-matrix;

  expectations = {
    "runs the frame sink" =
      lib.hasPrefix (lib.getExe cfg.cg.service.led-matrix.sinkPackage) unit.ExecStart;
    "listens on the frame socket" = socket.ListenSequentialPacket == "/run/led-matrix/frames.sock";
    "socket owned by root" = socket.SocketUser == "root";
    "socket group is led-matrix" = socket.SocketGroup == "led-matrix";
    "socket mode is 0660" = socket.SocketMode == "0660";
    "socket starts at boot" = lib.elem "sockets.target" cfg.systemd.sockets.led-matrix.wantedBy;
    "has no network" = unit.PrivateNetwork;
    "the sink links the module's library" =
      lib.elem patchedCfg.package patchedCfg.sinkPackage.buildInputs;
    "drops to led-matrix user" = lib.hasInfix "--led-drop-priv-user=led-matrix" unit.ExecStart;
    "drops to led-matrix group" = lib.hasInfix "--led-drop-priv-group=led-matrix" unit.ExecStart;
    "relaxes /dev/mem" = lib.elem "iomem=relaxed" cfg.boot.kernelParams;
    "isolates core 3" = lib.elem "isolcpus=3" cfg.boot.kernelParams;
    "raises the RT limit at boot" =
      cfg.boot.kernel.sysctl."kernel.sched_rt_runtime_us" or null == 990000;
    "sets core 3's governor at boot" =
      lib.any (lib.hasInfix "cpu3/cpufreq/scaling_governor") cfg.systemd.tmpfiles.rules;
    "keeps kernel tunables read-only" = unit.ProtectKernelTunables;
    "the renderer reads its location from sops" =
      renderer.LoadCredential == [ "location:${cfg.sops.secrets."matrix-display/location".path}" ];
    "the renderer has no capabilities" = renderer.CapabilityBoundingSet == "";
    "the renderer can reach the socket" = lib.elem socket.SocketGroup renderer.SupplementaryGroups;
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
