# Overlays for custom package modifications
{inputs, ...}: {
  # Custom packages from the packages/ directory
  additions = final: _prev: import ../packages final.pkgs;

  # Modifications to existing packages
  modifications = final: prev: {
    # Example:
    # somePackage = prev.somePackage.overrideAttrs (oldAttrs: {
    #   ...
    # });
  };

  # Access stable packages via pkgs.stable
  stable-packages = final: _prev: {
    stable = import inputs.nixpkgs-stable {
      system = final.system;
      config.allowUnfree = true;
    };
  };
}
