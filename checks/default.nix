# Behaviour tests - item 4 of docs/plans/deployment-hardening.md, and the
# primary pre-deploy gate per ADR 0002.
#
# The build gate proves that a host configuration evaluates and that its
# derivations realise. It proves nothing about whether the services that
# configuration ships actually start, or whether the config files they are
# handed are accepted by the programs that read them. Service configuration is
# the failure class this homelab actually experiences, so that gap is the
# whole point of this directory: these tests boot real VMs and assert against
# them.
#
# Exposed as flake `checks`, so `nix flake check` runs them and the existing
# `nixos ci` gate picks them up with no workflow changes.
#
# TEST MODULES, NOT HOSTS. A whole host configuration will not boot in a VM:
# disko expects real disks, ZFS expects a pool, sops expects host keys,
# homelab01 expects an NFS server on homelab02. Each test instantiates the
# service module under examination in an otherwise minimal machine, with
# secrets stubbed by ./lib.nix.
#
# NO NETWORK. The VMs run inside the Nix build sandbox, which has none. That
# is a constraint on what can be tested here rather than an inconvenience:
# anything whose behaviour depends on fetching something at runtime - every
# `virtualisation.oci-containers` service in modules/services, all of which
# pull `:latest` from a registry - cannot be started in this harness as
# written. See the `data-safety` discussion in the plan.
{
  pkgs,
  self,
  inputs,
}:
let
  testLib = import ./lib.nix { inherit pkgs self inputs; };
in
{
  # Static validation. Cheap, and worth keeping separate from the VM test
  # below: when both fail, which one failed says whether the rule file is
  # malformed or merely rejected in context.
  #
  # promtool lives in the `cli` output, not `out`.
  alert-rules =
    pkgs.runCommand "check-alert-rules" { nativeBuildInputs = [ pkgs.prometheus.cli ]; }
      ''
        promtool check rules ${../modules/services/monitoring/alert-rules.yml}
        touch $out
      '';

  digital-garden = testLib.mkTest ./digital-garden.nix;
  monitoring = testLib.mkTest ./monitoring.nix;
  reverse-proxy = testLib.mkTest ./reverse-proxy.nix;
}
