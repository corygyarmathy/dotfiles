# Shared plumbing for the behaviour tests in this directory.
#
# See ./default.nix for what these tests are for and why they instantiate
# service modules rather than whole hosts, and ./stub-secrets.nix for how they
# get around sops.
{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;
in
{
  # runNixOSTest with the specialArgs this repository's modules are written
  # against. `self` is not optional: several modules reach into self.packages
  # for things this flake builds itself, and one that does will not evaluate
  # without it.
  mkTest =
    module:
    pkgs.testers.runNixOSTest {
      imports = [ module ];

      # nixpkgs defaults this to an hour. Measured runtimes here are under two
      # minutes, so an hour does not bound anything - it just converts a hung
      # VM into a CI job that occupies a runner until someone notices. Ten
      # minutes is comfortably clear of the slowest test and still fails fast.
      # A test with a genuine reason to be slower should raise this itself,
      # and say why.
      globalTimeout = lib.mkDefault 600;

      # Applies to every node of every test.
      node.specialArgs = { inherit self inputs; };

      defaults = {
        # Option definitions only, until a secret is actually declared - so
        # this costs nothing for the tests that need no secrets, and saves
        # every test that does need one from remembering to import it.
        imports = [ inputs.sops-nix.nixosModules.sops ];

        # The VM has no persistent state and one job. Skip the parts of a real
        # host that only cost boot time here.
        documentation.enable = false;
      };
    };
}
