# checks/download-root-safety.nix
#
# Regression test for the static half of the download-root canary: the NixOS
# assertion that no service-declared output option equals the download root or
# is an ancestor of it, by path segment. The VM and host builds only exercise
# the pass-with-the-fleet-values case, which cannot tell a wrong segment
# boundary from a right one - this check pins the boundary itself.
#
# Each case evaluates a full media-stack host with suwayomi enabled and its
# downloadPath set to the path under test, then asks whether the resulting
# `download-root-safety` assertion fires. Only failing assertions have their
# message forced (some assertion messages in the wild would crash on a null
# while their assertion is actually true), and the guard's messages are plain
# strings, so this is safe.
{
  inputs,
  lib,
  pkgs,
  self,
}:
let
  mkEval =
    dpath:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit self inputs;
      };
      modules = [
        # The service modules assume sops-nix is imported (checks/lib.nix does
        # this for every test node).
        inputs.sops-nix.nixosModules.sops
        ../modules/services/media-stack/media-stack.nix
        ../modules/services/media-stack/download-root-canary.nix
        ../modules/services/media-stack/suwayomi.nix
        ../modules/services/monitoring/monitoring.nix
        ../modules/services/nas-storage.nix
        {
          cg.service.media-stack.enable = true;
          cg.service.suwayomi.enable = true;
          cg.service.suwayomi.downloadPath = dpath;
          system.stateVersion = "24.11";
        }
      ];
    };

  guardTripped =
    dpath:
    let
      failing = builtins.filter (a: !a.assertion) (mkEval dpath).config.assertions;
      messages = builtins.map (a: a.message) failing;
    in
    builtins.any (m: lib.hasPrefix "download-root-safety:" m) messages;

  mustTrip = [
    "/"
    "/srv/media/downloads"
    "/srv/media"
    "/srv/media/downloads/"
  ];
  mustPass = [
    "/srv/media/downloadsX"
    "/srv/media/downloads-extra"
    "/srv/media/suwayomi"
  ];

  tripList = lib.concatStringsSep " " (builtins.filter guardTripped mustTrip);
  expectTrip = lib.concatStringsSep " " mustTrip;
  passList = lib.concatStringsSep " " (builtins.filter (p: !guardTripped p) mustPass);
  expectPass = lib.concatStringsSep " " mustPass;
in
pkgs.runCommand "check-download-root-safety"
  {
    inherit
      tripList
      passList
      expectTrip
      expectPass
      ;
  }
  ''
    fail() { echo "FAIL: $*" >&2; exit 1; }

    if [ "$tripList" != "$expectTrip" ]; then
      fail "expected the guard to trip for [$expectTrip], got [$tripList]"
    fi
    if [ "$passList" != "$expectPass" ]; then
      fail "expected the guard to pass for [$expectPass], got [$passList]"
    fi

    touch "$out"
    echo "ok: download-root-safety"
  ''
