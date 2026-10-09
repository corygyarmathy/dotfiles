# Every host that serves the garden serves the site lib/site.nix describes.
#
# `nix run .#garden-preview` builds its pipeline from lib/site.nix and
# evaluates no host, so it only shows what the server serves while no host
# overrides the site's settings. The module's comment says to change the site
# in lib/site.nix rather than in hosts/; this is what holds a host to that.
# Without it, a footer link set in hosts/ would ship to the server and never
# appear in the preview, and nothing would say so.
#
# Not a VM: which settings a host ends up with is a question about evaluation.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  site = import ../modules/services/digital-garden/lib/site.nix {
    inherit ((import ../fleet)) domain;
  };

  serving = lib.filterAttrs (
    # Workstations import no service modules at all, hence the `or`.
    _: host: host.config.cg.service.digital-garden.enable or false
  ) self.nixosConfigurations;

  # "<host>: <option>" for each setting a serving host has away from the site.
  overridden = lib.concatLists (
    lib.mapAttrsToList (
      name: host:
      lib.mapAttrsToList (option: _: "${name}: cg.service.digital-garden.${option}") (
        lib.filterAttrs (option: value: host.config.cg.service.digital-garden.${option} != value) site
      )
    ) serving
  );
in
assert lib.assertMsg (serving != { }) "no host serves the garden, so this check checks nothing";
pkgs.runCommand "check-digital-garden-site" { } (
  if overridden == [ ] then
    "touch $out"
  else
    ''
      echo "these settings differ from modules/services/digital-garden/lib/site.nix," >&2
      echo "so garden-preview no longer shows what the host serves. Change the site there:" >&2
      ${lib.concatMapStringsSep "\n" (line: "echo ${lib.escapeShellArg "  ${line}"} >&2") overridden}
      exit 1
    ''
)
