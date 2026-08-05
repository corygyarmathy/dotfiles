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

    # Hyprland's CMake asks for `glaze 7...<8`, but nixpkgs bumped glaze to
    # 8.0.0, so find_package fails and CMake quietly falls back to fetching
    # glaze over the network — which the build sandbox blocks.
    # https://github.com/NixOS/nixpkgs/issues/549246
    #
    # This is upstream's own fix, backported verbatim. It is merged to master
    # but has not reached nixos-unstable yet.
    # TODO: drop once the channel includes https://github.com/NixOS/nixpkgs/pull/549253
    hyprland = prev.hyprland.overrideAttrs (old: {
      postPatch = ''
        substituteInPlace CMakeLists.txt start/CMakeLists.txt hyprpm/CMakeLists.txt \
          --replace-fail "glaze 7...<8" "glaze"
      ''
      + old.postPatch;
    });
  };

  # Access stable packages via pkgs.stable
  stable-packages = _final: prev: {
    stable = import inputs.nixpkgs-stable {
      inherit (prev.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

  # Access unstable-small packages via pkgs.unstable-small
  unstable-small-packages = _final: prev: {
    small = import inputs.nixpkgs-unstable-small {
      inherit (prev.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
}
