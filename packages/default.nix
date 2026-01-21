# Custom packages
# Build with: nix build .#packageName
pkgs: {
  # NixOS upgrade management scripts
  nixos-upgrade-scripts = pkgs.callPackage ./nixos-upgrade-scripts { };

  # External monitor brightness scripts
  ddc-brightness-scripts = pkgs.callPackage ./ddc-brightness-scripts { };

  # Remote install (w/ nixos-anywhere)
  nixos-remote-install = pkgs.callPackage ./nixos-remote-install { };

  # Example custom package:
  # bootdevcli = pkgs.callPackage ./bootdevcli {};
}
