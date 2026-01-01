# Custom packages
# Build with: nix build .#packageName
pkgs: {
  # NixOS upgrade management scripts
  nixos-upgrade-scripts = pkgs.callPackage ./nixos-upgrade-scripts { };

  # Example custom package:
  # bootdevcli = pkgs.callPackage ./bootdevcli {};
}
