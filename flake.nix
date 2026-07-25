{
  description = "Cory's NixOS Configuration";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable-small.url = "github:nixos/nixpkgs/nixos-unstable-small";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-26.05";

    nixpkgs-claude-code-2-1-219.url = "github:samestep/nixpkgs/claude-code-2.1.219";

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

              # Nix settings
              nix = {
                settings = {
                  experimental-features = [
                    "nix-command"
                    "flakes"
                  ];
                  # Hyprland cachix
                  substituters = [ "https://hyprland.cachix.org" ];
                  trusted-public-keys = [ "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=" ];
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

      # Development shell for working on this config
      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            nil # Nix LSP
            nixfmt-rfc-style
            sops
            age
            ssh-to-age
            (callPackage ./packages/nixos-remote-install { })
          ];
        };
      });
    };
}
