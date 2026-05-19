# Custom packages
# Build with: nix build .#packageName
pkgs: {
  # NixOS upgrade management scripts
  nixos-upgrade-scripts = pkgs.callPackage ./nixos-upgrade-scripts { };

  # External monitor brightness scripts
  ddc-brightness-scripts = pkgs.callPackage ./ddc-brightness-scripts { };

  # Remote install (w/ nixos-anywhere)
  nixos-remote-install = pkgs.callPackage ./nixos-remote-install { };

  # Commercial skip
  comskip = pkgs.callPackage ./comskip { };

  # Argtable2 (dependency for comskip)
  argtable2 = pkgs.callPackage ./argtable2 { };

  # Custom script to take comskip output and make chapters in media
  comskip-chapters = pkgs.callPackage ./comskip-chapters { };

  # Custom script to take comskip output and cut commercials from media
  comskip-cut = pkgs.callPackage ./comskip-cut { };

  # Media player waybar module
  waybar-media = pkgs.callPackage ./waybar-media { };

  # Example custom package:
  # bootdevcli = pkgs.callPackage ./bootdevcli {};
}
