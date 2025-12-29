{
  description = "Cory's NixOS Configuration";

  inputs = {
    # Nixpkgs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-unstable-small.url = "github:nixos/nixpkgs/nixos-unstable-small";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.11";

    # Home Manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Hardware quirks
    hardware.url = "github:nixos/nixos-hardware";

    # Theming
    stylix.url = "github:danth/stylix";

    # Hyprland (latest)
    hyprland.url = "git+https://github.com/hyprwm/Hyprland?submodules=1";
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    # Secrets management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
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
      hyprland,
      hyprland-plugins,
      sops-nix,
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

            # Core module systems
            home-manager.nixosModules.home-manager
            stylix.nixosModules.stylix
            sops-nix.nixosModules.sops

            # Shared configuration for all hosts
            {
              networking.hostName = hostname;

              # Home-manager settings
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = { inherit inputs self; };
                sharedModules = [
                  sops-nix.homeManagerModules.sops
                ];
              };

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
          ]
          ++ extraModules;
        };
    in
    {
      # NixOS configurations for each host
      nixosConfigurations = {
        xps15 = mkHost {
          hostname = "xps15";
          system = "x86_64-linux";
          extraModules = [
            # XPS15-specific hardware modules from nixos-hardware
            hardware.nixosModules.common-cpu-intel
            hardware.nixosModules.common-pc-laptop
            hardware.nixosModules.common-pc-laptop-ssd
            hardware.nixosModules.common-gpu-nvidia
          ];
        };

        # Future hosts can be added like:
        # server = mkHost {
        #   hostname = "server";
        #   system = "x86_64-linux";
        # };
      };

      # Overlays exported by this flake
      overlays = import ./overlays { inherit inputs; };

      # Custom packages
      packages = forAllSystems (system: import ./packages nixpkgs.legacyPackages.${system});

      # Development shell for working on this config
      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            nil # Nix LSP
            nixfmt-rfc-style
            sops
            age
          ];
        };
      });
    };
}
