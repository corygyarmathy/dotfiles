# Replace sops decryption with plaintext fixtures, for tests.
#
# sops cannot decrypt inside a test VM. It derives its age key from the SSH
# host key (modules/nixos/sops-nix.nix), and a VM built in the Nix sandbox has
# neither that key nor any way to be handed one without committing a
# decryption key to this repository.
#
# So short-circuit it rather than reproduce it: point each secret and template
# at a plaintext fixture in the store, and switch off the installer that would
# otherwise try to decrypt the real file.
#
# What this deliberately does NOT do is remove the module's own
# `sops.secrets.<name>` and `sops.templates.<name>` declarations. Those stay,
# so a test still covers the wiring between a module and the secret names it
# consumes - only the decryption step is replaced. Name a secret here that the
# module under test does not declare and the override lands on nothing, which
# is a silent pass; name one it does and the fixture is what it reads.
#
# The cost is that these tests prove nothing about sops itself. That is the
# trade the plan names; the more faithful alternative - a throwaway age key
# committed here alongside an encrypted fixture file - is available if a test
# ever needs to cover the sops wiring rather than work around it.
#
# Usage, from a test's node definition:
#
#   imports = [
#     (import ./stub-secrets.nix {
#       secrets."cloudflare/api-token" = "not-a-real-token";
#       templates."caddy-cloudflare-env" = "CF_API_TOKEN=not-a-real-token\n";
#     })
#   ];
{
  secrets ? { },
  templates ? { },
}:
{ lib, pkgs, ... }:
let
  # The name is a sops key path, so it contains slashes; only the last segment
  # is usable as a store path name.
  fixture = name: content: toString (pkgs.writeText "stub-${baseNameOf name}" content);
in
{
  sops.secrets = lib.mapAttrs (name: content: {
    path = lib.mkForce (fixture name content);
  }) secrets;

  sops.templates = lib.mapAttrs (name: content: {
    path = lib.mkForce (fixture name content);
  }) templates;

  # Satisfies sops-nix's "no key source configured" assertion, which fires as
  # soon as any secret is declared. Nothing reads the path, because the unit
  # that would is disabled just below.
  sops.age.sshKeyPaths = lib.mkForce [ "/etc/ssh/ssh_host_ed25519_key" ];

  # sops-nix installs secrets from one of two places depending on
  # `useSystemdActivation`. Disable both rather than depend on which is in
  # force, since the answer is an upstream default that can move.
  systemd.services.sops-install-secrets.enable = false;
  system.activationScripts.setupSecrets = lib.mkForce "";
}
