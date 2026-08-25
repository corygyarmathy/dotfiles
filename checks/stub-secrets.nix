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
#
# Secrets named in `private` are installed differently: copied to
# /run/stub-secrets/<name> with the owner, group and mode each secret
# declares (sops-nix's defaults being root:root 0400), which is what
# production gets. Use this for secrets a non-root service reads directly,
# so the test fails the way production would if the module forgot to
# declare an owner - store fixtures are world-readable and mask exactly
# that bug class.
{
  secrets ? { },
  templates ? { },
  private ? [ ],
}:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  # The name is a sops key path, so it contains slashes; only the last segment
  # is usable as a store path name.
  fixture = name: content: toString (pkgs.writeText "stub-${baseNameOf name}" content);

  privateInstall =
    name:
    let
      s = config.sops.secrets.${name};
      # This pinned sops-nix leaves owner/group null and installs as
      # uid/gid 0 when unset; resolve them the way its installer would.
      owner = if s.owner != null then s.owner else "root";
      group = if s.group != null then s.group else config.users.users.${owner}.group or "root";
    in
    ''
      mkdir -p "/run/stub-secrets/$(dirname "${name}")"
      install -m ${s.mode} -o ${owner} -g ${group} "${fixture name secrets.${name}}" "/run/stub-secrets/${name}"
    '';
in
{
  sops.secrets = lib.mapAttrs (name: content: {
    path =
      if lib.elem name private then
        lib.mkForce "/run/stub-secrets/${name}"
      else
        lib.mkForce (fixture name content);
  }) secrets;

  sops.templates = lib.mapAttrs (name: content: {
    path = lib.mkForce (fixture name content);
  }) templates;

  # Installs the `private` fixtures under their declared ownership.
  # Runs in activation, so the files exist before any service starts; /run
  # is tmpfs, and activation runs on every boot for exactly this reason.
  system.activationScripts.stubPrivateSecrets = lib.mkIf (private != [ ]) (
    lib.stringAfter [ "etc" ] (lib.concatMapStringsSep "\n" privateInstall private)
  );

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
