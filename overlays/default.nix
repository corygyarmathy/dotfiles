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
    # TODO: revert once https://github.com/NixOS/nixpkgs/issues/514113 resolved
    openldap = prev.openldap.overrideAttrs (oldAttrs: {
      doCheck = false;
    });
  };

  # Access stable packages via pkgs.stable
  stable-packages = final: _prev: {
    stable = import inputs.nixpkgs-stable {
      system = final.system;
      config.allowUnfree = true;
    };
  };
}
