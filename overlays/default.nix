# Overlays for custom package modifications
{ inputs, ... }:
{
  # Custom packages from the packages/ directory
  additions = final: _prev: import ../packages final;

  # Modifications to existing packages
  modifications = final: prev: {
    # Example:
    # somePackage = prev.somePackage.overrideAttrs (oldAttrs: {
    #   ...
    # });
    #

    # https://github.com/NixOS/nixpkgs/pull/545319
    # TODO: Remove this overlay once the PR is merged and available on unstable.
    claude-code =
      (import inputs.nixpkgs-claude-code-2-1-219 {
        system = final.system;
        config.allowUnfree = true;
      }).claude-code;

    # Disable openldap tests only for 32-bit builds (triggered by Steam's
    # multilib support). The i686 build isn't cached by Hydra and the
    # syncreplication test fails in the Nix sandbox.
    # https://github.com/NixOS/nixpkgs/issues/514113
    openldap = prev.openldap.overrideAttrs (
      old:
      final.lib.optionalAttrs final.stdenv.is32bit {
        doCheck = false;
      }
    );
  };

  # Access stable packages via pkgs.stable
  stable-packages = final: _prev: {
    stable = import inputs.nixpkgs-stable {
      system = final.system;
      config.allowUnfree = true;
    };
  };

  # Access unstable-small packages via pkgs.unstable-small
  unstable-small-packages = final: _prev: {
    small = import inputs.nixpkgs-unstable-small {
      system = final.system;
      config.allowUnfree = true;
    };
  };
}
