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

    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (_pyFinal: pyPrev: {
        # The tinydtls bundled in DTLSSocket defaults to
        # force_renegotiation_info, aborting with handshake_failure when a
        # ServerHello lacks the RFC 5746 extension. IKEA TRÅDFRI gateway
        # firmware 1.21.0057 omits it, so Home Assistant's tradfri pairing
        # (homelab01) times out with a correct security code. DTLSSocket does
        # not expose the parameter, so this flips the compiled-in default.
        # The extension guards against renegotiation attacks, and tinydtls
        # never renegotiates (it supports only RFC 5746's initial-handshake
        # form), so nothing is lost. No guard: --replace-fail fails the build when a bump
        # changes the line, at which point check whether it is still needed.
        dtlssocket = pyPrev.dtlssocket.overridePythonAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace DTLSSocket/tinydtls/dtls.c \
              --replace-fail '.force_renegotiation_info = 1,' '.force_renegotiation_info = 0,'
          '';
        });
      })
    ];

    # TEMPORARY: when an MST output (DP-4 on xps15) comes up connected but
    # modeless, a blur-property refresh builds framebuffers for its 0x0 size
    # and Hyprland aborts in IFramebuffer::alloc; greetd restarts it into the
    # same abort. The patch skips modeless monitors in that refresh. No
    # upstream fix exists (both reports were closed without one), so there is
    # no guard: when a Hyprland bump stops the patch applying, the xps15 build
    # fails and someone must check whether upstream now handles it. Delete it
    # too once upstream guards the 0x0 case anywhere else (for example in
    # CMonitor::resources()), since the patch would still apply but be dead.
    # https://github.com/corygyarmathy/dotfiles/issues/406
    # https://github.com/hyprwm/Hyprland/issues/16370
    hyprland = prev.hyprland.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./hyprland-skip-modeless-monitor-blur-refresh.patch ];
    });

    # TEMPORARY: since nixpkgs 58d0d3e (2026-11-24) hadolint's dependencies
    # fail Cabal's bounds check against GHC 9.12's boot packages:
    # language-docker 16.0.0 wants time <1.14 (GHC ships 1.14) and spdx
    # 1.1.0.1 excludes Cabal-syntax 3.14. Both build and pass their test
    # suites with the bounds dropped. Scoped to hadolint rather than
    # haskellPackages so nothing else rebuilds. Delete once
    # `nix path-info --store https://cache.nixos.org` finds the unpatched
    # pkgs.hadolint outPath, i.e. upstream has fixed the bounds.
    hadolint =
      let
        hl = final.haskell.lib.compose;
        haskellPackages = prev.haskellPackages.override (old: {
          overrides = final.lib.composeExtensions (old.overrides or (_: _: { })) (
            _hfinal: hprev: {
              language-docker = hl.doJailbreak hprev.language-docker;
              spdx = hl.doJailbreak hprev.spdx;
            }
          );
        });
      in
      hl.justStaticExecutables haskellPackages.hadolint;
  };

  # Access stable packages via pkgs.stable
  stable-packages = _final: prev: {
    stable = import inputs.nixpkgs-stable {
      inherit (prev.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

  # matrix-display-sink, the LED matrix's default command (ADR 0011). It links
  # the `rpi-rgb-led-matrix` of the pkgs it lands in, so `additions` supplies
  # ours. Lazy, so hosts without the display never build it.
  matrix-display = inputs.matrix-display.overlays.default;

  # Access unstable-small packages via pkgs.unstable-small
  unstable-small-packages = _final: prev: {
    small = import inputs.nixpkgs-unstable-small {
      inherit (prev.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
}
