{
  description = "Cory's NixOS Configuration";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable-small.url = "github:nixos/nixpkgs/nixos-unstable-small";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-26.05";

    # Home Manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Hardware quirks
    hardware.url = "github:nixos/nixos-hardware";

    # Theming
    stylix.url = "github:nix-community/stylix";
    stylix.inputs.nixpkgs.follows = "nixpkgs";

    # Secrets management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Declarative disk partitioning
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      nixpkgs-unstable-small,
      home-manager,
      hardware,
      stylix,
      sops-nix,
      disko,
      ...
    }@inputs:
    let
      # Supported systems
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Helper function to create a NixOS host configuration
      mkHost =
        {
          hostname,
          system ? "x86_64-linux",
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit inputs self;
            # Make stable packages available as pkgs-stable
            pkgs-stable = import nixpkgs-stable {
              inherit system;
              config.allowUnfree = true;
            };
            # Make unstable-small packages available as pkgs-small
            pkgs-small = import nixpkgs-unstable-small {
              inherit system;
              config.allowUnfree = true;
            };
          };
          modules = [
            # Host-specific configuration
            ./hosts/${hostname}

            # Core module schemas loaded globally
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            stylix.nixosModules.stylix # Loaded here so all hosts recognize Stylix syntax

            # Apply custom overlays
            { nixpkgs.overlays = builtins.attrValues self.overlays; }

            # Shared configuration for all hosts
            {
              networking.hostName = hostname;

              # Record the flake revision this system was built from, so a host
              # can report what it is actually running (see docs/adr/0001).
              # `self.rev` only exists for a clean tree; fall back to dirtyRev
              # for local `nixos-rebuild` from a working copy.
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";

              # Nix settings
              nix = {
                settings = {
                  experimental-features = [
                    "nix-command"
                    "flakes"
                  ];
                  substituters = [
                    # Hyprland cachix
                    "https://hyprland.cachix.org"
                    # Our own CI builds - every host toplevel is pushed here by
                    # .github/workflows/ci.yml, so the nightly autoUpgrade
                    # substitutes the closure instead of rebuilding it (ADR 0001).
                    "https://corygyarmathy-dotfiles.cachix.org"
                  ];
                  trusted-public-keys = [
                    "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
                    "corygyarmathy-dotfiles.cachix.org-1:/DMVcdDI+4GCAzS6iDTtiwERF1py+MD+w1Z/NTAd2oU="
                  ];
                  # Without this, `nixos-rebuild --target-host` only works for
                  # a closure the target can substitute from Cachix. Anything
                  # built locally - which is every change not yet through CI,
                  # i.e. exactly what interactive iteration is for - is
                  # unsigned, and the remote daemon rejects it for an untrusted
                  # user with "lacks a signature by a trusted key".
                  #
                  # Be clear-eyed about what this grants: a trusted user can
                  # add arbitrary paths to the store and name its own
                  # substituters, which is root-equivalent in practice. It is
                  # not much of a widening here, since wheel already has sudo
                  # and anything that can set the system profile can point it
                  # at a closure containing a root shell - but it is a real
                  # one, and it is the reason this is `@wheel` rather than
                  # `*`.
                  #
                  # `@wheel` alone: the option is a merged list and nixpkgs
                  # already contributes `root`.
                  trusted-users = [ "@wheel" ];
                };
                # Automatic garbage collection
                gc = {
                  automatic = true;
                  dates = "weekly";
                  options = "--delete-older-than 14d";
                };
                # Automatic store optimisation
                optimise = {
                  automatic = true;
                  dates = [ "22:00" ];
                };
              };

              # Allow unfree packages
              nixpkgs.config.allowUnfree = true;
            }

            # Global Home Manager Configuration Setup
            home-manager.nixosModules.home-manager

            # Convert this block into an inline NixOS module function.
            # This gives native, clean access to the host's root `config` and `lib`.
            (
              { config, lib, ... }:
              {
                home-manager = {
                  useGlobalPkgs = true;
                  useUserPackages = true;
                  extraSpecialArgs = { inherit inputs self; };

                  # Dynamically construct our shared Home Manager modules list
                  sharedModules = [
                    sops-nix.homeManagerModules.sops
                  ]
                  ++ lib.optional (!config.cg.stylix.enable) inputs.stylix.homeModules.stylix;
                  # ^ If system-level stylix is NOT enabled (like on servers),
                  # safely inject the schema so `stylix-hm.nix` doesn't crash!
                };
              }
            )
          ]
          ++ extraModules;
        };
    in
    {
      # NixOS configurations for each host
      nixosConfigurations = {
        # Desktop: Dell XPS 15 9500
        xps15 = mkHost {
          hostname = "xps15";
          extraModules = [
            hardware.nixosModules.dell-xps-15-9500-nvidia
          ];
        };

        # Server: Dell Optiplex 5080
        homelab01 = mkHost {
          hostname = "homelab01";
          extraModules = [
            hardware.nixosModules.common-cpu-intel
            hardware.nixosModules.common-pc
            hardware.nixosModules.common-pc-ssd
          ];
        };

        # Server: HP Elitedesk 800 G6 SFF
        homelab02 = mkHost {
          hostname = "homelab02";
          extraModules = [
            hardware.nixosModules.common-cpu-intel
            hardware.nixosModules.common-pc
            hardware.nixosModules.common-pc-ssd
          ];
        };
      };

      # Overlays exported by this flake
      overlays = import ./overlays { inherit inputs; };

      # Custom packages
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = builtins.attrValues self.overlays;
            config.allowUnfree = true;
          };
        in
        import ./packages pkgs
      );

      # Local preview for the digital garden:
      #
      #   nix run .#garden-preview
      #   nix run .#garden-preview -- --fixture
      #
      # The first renders the published subset of the vault with the same
      # renderer and serves it with the same Caddy config the server uses,
      # re-rendering on save. See modules/services/digital-garden/lib/preview.nix
      # for why.
      #
      # The second renders the theme's own fixture instead: every element the
      # stylesheet styles, on three pages, which is what a visual change is
      # judged against - the vault is a poor test of a stylesheet, because it
      # contains whatever it happens to contain.
      #
      # The renderer comes out of homelab01's own evaluated config rather than
      # being rebuilt here, so the preview cannot drift from what is deployed.
      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = builtins.attrValues self.overlays;
            config.allowUnfree = true;
          };
          garden = self.nixosConfigurations.homelab01.config.cg.service.digital-garden;
          # caddyConfig takes no settings, so importing serve.nix again for it
          # duplicates no configuration - unlike the renderer, which is read
          # out of the host's own evaluated config below.
          serve = import ./modules/services/digital-garden/lib/serve.nix {
            inherit (nixpkgs) lib;
          };
          preview = import ./modules/services/digital-garden/lib/preview.nix {
            inherit pkgs serve;
            inherit (nixpkgs) lib;
            inherit (garden) renderer styleSheet;
            filter = ./modules/services/digital-garden/publish-filter.py;
            workingTreeStyleSheet = "modules/services/digital-garden/lib/hugo/assets/main.css";
            fixture = ./modules/services/digital-garden/lib/hugo/fixture;
            workingTreeFixture = "modules/services/digital-garden/lib/hugo/fixture";
          };
        in
        {
          garden-preview = {
            type = "app";
            program = nixpkgs.lib.getExe preview;
          };
        }
      );

      # Checks run by `nix flake check`, and therefore by the CI gate.
      #
      # Building a host proves its Nix evaluates, not that the services it
      # ships come up or that the config files they are handed are valid. See
      # ./checks for what lives here and why.
      #
      # x86_64-linux only. Every host is x86_64, and a NixOS VM test for
      # another system needs a builder for it - `nix flake check` would
      # evaluate a whole foreign NixOS system just to skip building it.
      checks = {
        x86_64-linux = import ./checks {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = builtins.attrValues self.overlays;
            config.allowUnfree = true;
          };
          inherit self inputs;
        };
      };

      # Development shell for working on this config
      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            nil # Nix LSP
            nixfmt
            sops
            age
            ssh-to-age
            (callPackage ./packages/nixos-remote-install { })
          ];
        };
      });

      # `nix fmt` formats the tree; `nix fmt -- --ci` is what the `fmt` CI job
      # runs, and fails on anything it would have changed.
      #
      # `nixfmt-tree` rather than bare `nixfmt`: `nix fmt` hands the formatter
      # a directory, and nixfmt has deprecated directory arguments in favour of
      # exactly this wrapper. It is treefmt with nixfmt configured, so it also
      # walks the tree honouring .gitignore instead of formatting whatever it
      # is pointed at.
      #
      # Taken from this flake's own nixpkgs rather than whatever happens to be
      # on a PATH, so the version deciding the gate is the version in
      # flake.lock - otherwise a contributor's newer nixfmt reformats files CI
      # then rejects, and the two never agree.
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
