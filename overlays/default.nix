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

    # TEMPORARY: speechd lists python as a buildInput rather than a
    # nativeBuildInput, so its Python client library is not built and
    # calibre's test_speech_dispatcher fails on xps15. Scoped to calibre's own
    # speechd-minimal: overriding speechd globally rebuilds firefox. The guard
    # makes this inert once the fix lands, after which delete it.
    # https://github.com/NixOS/nixpkgs/pull/576062
    calibre = prev.calibre.override {
      speechd-minimal = prev.speechd-minimal.overrideAttrs (
        old:
        let
          isPython = p: p ? pythonVersion;
          pythons = builtins.filter isPython (old.buildInputs or [ ]);
        in
        final.lib.optionalAttrs (pythons != [ ]) {
          nativeBuildInputs = old.nativeBuildInputs ++ pythons;
          buildInputs = builtins.filter (p: !isPython p) old.buildInputs;
        }
      );
    };

    # TEMPORARY: unity builds of audacity 4.0.0's extensions QML module clash
    # with names in Qt 6.12's generated QML code, so xps15 fails to compile.
    # Applies upstream's NO_UNITY fix; the guard makes this inert once it
    # lands, after which delete it.
    # https://github.com/NixOS/nixpkgs/pull/577022
    audacity = prev.audacity.overrideAttrs (
      old:
      final.lib.optionalAttrs (!final.lib.hasInfix "NO_UNITY" (old.postPatch or "")) {
        postPatch = ''
          substituteInPlace muse/framework/extensions/qml/Muse/Extensions/CMakeLists.txt \
            --replace-fail 'ALIAS muse::extensions_qml' 'NO_UNITY ALIAS muse::extensions_qml'
        ''
        + (old.postPatch or "");
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

        # TEMPORARY: Cython 3.3.0 type-checks list[str] elements itself, so a
        # pyopenjtalk-plus test expecting the package's own "must be str"
        # TypeError fails, breaking piper-tts and calibre on xps15.
        # Applies upstream's test fix; the name guard makes this inert once
        # nixpkgs carries the same patch, after which delete it.
        # https://github.com/NixOS/nixpkgs/pull/576063
        pyopenjtalk-plus = pyPrev.pyopenjtalk-plus.overridePythonAttrs (
          old:
          let
            patchName = "fix-cython-3.3.0.patch";
          in
          final.lib.optionalAttrs (!builtins.any (p: (p.name or "") == patchName) (old.patches or [ ])) {
            patches = (old.patches or [ ]) ++ [
              (final.fetchpatch {
                name = patchName;
                url = "https://github.com/tsukumijima/pyopenjtalk-plus/commit/90b644f9e9d397882e6eafe4dcd1843a4fde6a63.patch";
                includes = [ "tests/test_frontend.py" ];
                hash = "sha256-Jb7T/bRUHxqwBLwV6xYC/teaFHm5GmqJxA7sCX+oiNI=";
              })
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
