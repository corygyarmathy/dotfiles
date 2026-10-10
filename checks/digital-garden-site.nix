# Every host that serves the garden serves the site the garden repository's
# preview renders.
#
# The preview lives in the garden repository and evaluates no host: it hands
# that repository's lib/site.nix to its pipeline, with the domain stated a
# second time in its flake.nix because a checkout of it has no fleet to ask.
# So it only shows what the server serves while two things hold, and this
# check holds both:
#
# - No serving host overrides the site's settings. The module's comment says
#   to change the site in the garden repository rather than in hosts/; without
#   this, a footer link set in hosts/ would ship to the server and never
#   appear in the preview, and nothing would say so.
# - The garden flake's domain is the fleet's. Its packages.renderer is built
#   from this flake's nixpkgs (the input follows ours) and its own `lib.site`,
#   so it is the same derivation as one built from `lib.site` with the fleet's
#   domain exactly when the two domains agree.
#
# Not a VM: which settings a host ends up with is a question about evaluation.
{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
  inherit ((import ../fleet)) domain;
  garden = inputs.digital-garden;
  site = garden.lib.site { inherit domain; };

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

  previewRenderer = garden.packages.${pkgs.stdenv.hostPlatform.system}.renderer;
  fleetRenderer =
    (garden.lib.mkGarden (
      {
        pkgs = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      }
      // site
    )).renderer;
  domainAgrees = previewRenderer.drvPath == fleetRenderer.drvPath;
in
assert lib.assertMsg (serving != { }) "no host serves the garden, so this check checks nothing";
pkgs.runCommand "check-digital-garden-site" { } (
  lib.optionalString (overridden != [ ]) ''
    echo "these settings differ from the garden repository's lib/site.nix," >&2
    echo "so its preview no longer shows what the host serves. Change the site there:" >&2
    ${lib.concatMapStringsSep "\n" (line: "echo ${lib.escapeShellArg "  ${line}"} >&2") overridden}
  ''
  + lib.optionalString (!domainAgrees) ''
    echo "the garden repository's flake.nix renders its preview for a domain other" >&2
    echo ${lib.escapeShellArg "than the fleet's (${domain}), so its preview no longer shows what the host serves."} >&2
  ''
  + (if overridden == [ ] && domainAgrees then "touch $out" else "exit 1")
)
