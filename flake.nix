{
  description = "Your new nix config";

  inputs = {
    # Nixpkgs
    # TODO: change to the most recent channel URL
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.05";
    # You can access packages and modules from different nixpkgs revs
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Also see the 'unstable-packages' overlay at 'overlays/default.nix'.
    nixpkgs-unstable-small.url = "github:nixos/nixpkgs/nixos-unstable-small";

    # Home manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Imports hardware dependencies
    hardware.url = "github:nixos/nixos-hardware";

    # Used for setting system colours / styling
    stylix.url = "github:danth/stylix";

    # Hyprland
    hyprland.url = "git+https://github.com/hyprwm/Hyprland?submodules=1"; # Use most recent version
    # Import the Hyprland plugin manager
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    # SOPS-Nix
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
      stylix,
      sops-nix,
      ...
    }@inputs:
    let
      inherit (self) outputs;
      # TODO: investigate this option - not exactly sure what it should be set to. Okay to leave as is?
      # Supported systems for your flake packages, shell, etc.
      systems = [
        "aarch64-linux"
        "i686-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      # This is a function that generates an attribute by calling a function you
      # pass to it, with each system as an argument
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Your custom packages
      # Accessible through 'nix build', 'nix shell', etc
      packages = forAllSystems (system: import ./pkgs/nixos-pkgs nixpkgs.legacyPackages.${system});

      # Formatter for your nix files, available through 'nix fmt'
      # Other options beside 'alejandra' include 'nixpkgs-fmt'
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra); # TODO: use this formatter?

      # Your custom packages and modifications, exported as overlays
      overlays = import ./nixos/nixos-overlays { inherit inputs; };

      # Reusable nixos modules you might want to export
      nixosModules = import ./nixos/nixos-modules/nixos;

      # Reusable home-manager modules you might want to export
      # FIXME: this doesn't work for some reason (infinite recursion error)
      # homeManagerModules = import ./nixos/nixos-modules/home-manager;

      # NixOS configuration entrypoint
      # Available through 'nixos-rebuild --flake .#your-hostname'
      nixosConfigurations = {
        # NOTE: the below ' x = ' defines the hostname, which is set by networking.hostname
        xps15 = nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit inputs outputs;
          };
          modules = [
            ./nixos/hosts/xps15/configuration.nix # > Our main nixos configuration file <
            stylix.nixosModules.stylix # Enable configuration through Stylix, bundles home-manager module
            sops-nix.nixosModules.sops

            # make home-manager as a module of nixos
            # so that home-manager configuration will be deployed automatically when executing `nixos-rebuild switch`
            home-manager.nixosModules.home-manager
            {
              home-manager.users.coryg = import ./nixos/home-manager/home.nix;
              # pkgs = nixpkgs.legacyPackages.x86_64-linux; # Home-manager requires 'pkgs' instance
              home-manager.extraSpecialArgs = {
                inherit inputs outputs;
              };

              # Optionally, use home-manager.extraSpecialArgs to pass arguments to home.nix
            }
          ];
        };
      };
    };
}
