# checks/afk-agent-assertions.nix
#
# The afk-agent module's eval-time assertions, each made to fire. The VM check
# boots one configuration that satisfies all of them, so it cannot tell a
# working guard from one that never fires - this check can.
#
# Each case is homelab01 with one change, so the guard is tested against what
# production evaluates rather than a copy of it. Only failing assertions have
# their message forced, as in ./download-root-safety.nix.
#
# Covers the intake pair so far; the module's other assertions are #296's.
{
  lib,
  pkgs,
  self,
}:
let
  pairMessage = "cg.service.afk-agent: set eligibilityLabel and reviewQueueLimit together, or neither (intake is then off, and commands still work)";

  failing =
    afk:
    let
      eval = self.nixosConfigurations.homelab01.extendModules {
        modules = [ { cg.service.afk-agent = lib.mapAttrs (_: lib.mkForce) afk; } ];
      };
    in
    map (a: a.message) (builtins.filter (a: !a.assertion) eval.config.assertions);

  cases = {
    "homelab01 as written" = {
      afk = { };
      fires = false;
    };
    "intake off" = {
      afk = {
        eligibilityLabel = null;
        reviewQueueLimit = null;
      };
      fires = false;
    };
    "label without a limit" = {
      afk.reviewQueueLimit = null;
      fires = true;
    };
    "limit without a label" = {
      afk.eligibilityLabel = null;
      fires = true;
    };
  };

  wrong = lib.concatStringsSep ", " (
    lib.attrNames (lib.filterAttrs (_: c: lib.elem pairMessage (failing c.afk) != c.fires) cases)
  );
in
pkgs.runCommand "check-afk-agent-assertions" { inherit wrong; } ''
  if [ -n "$wrong" ]; then
    echo "FAIL: the intake-pair assertion is wrong for: $wrong" >&2
    exit 1
  fi
  touch "$out"
  echo "ok: afk-agent-assertions"
''
