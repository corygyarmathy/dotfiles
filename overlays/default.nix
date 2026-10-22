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
      final.lib.optionalAttrs final.stdenv.hostPlatform.is32bit {
        doCheck = false;
      }
    );

    # TEMPORARY: diff-cover 10.5.1's HTML golden files expect raw `"` but the
    # highlighter now emits `&quot;`, breaking sqlfluff (nvim) on every host.
    # Fixed by the 10.6.0 bump; the version guard makes this inert once it
    # lands, after which delete it.
    # https://github.com/NixOS/nixpkgs/issues/576851
    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (_pyFinal: pyPrev: {
        diff-cover = pyPrev.diff-cover.overridePythonAttrs (
          old:
          final.lib.optionalAttrs (old.version == "10.5.1") {
            disabledTests = (old.disabledTests or [ ]) ++ [
              "test_added_file_pycodestyle_html"
              "test_added_file_pyflakes_html"
              "test_added_file_pylint_html"
              "test_all_reports"
              "test_fail_under_html"
              "test_fail_under_pass_html"
            ];
          }
        );
      })
    ];
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
