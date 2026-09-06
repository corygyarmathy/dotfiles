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

  # The shared rofi dmenu wrapper every desktop menu goes through
  rofi-menu = pkgs.callPackage ./rofi-menu { };

  # Desktop menus - items 8, 9, 10 and 13 of docs/plans/desktop-design.md,
  # all built with lib/mk-menu.nix so they cannot drift into looking like
  # four menus. The builder itself is not a package and deliberately does not
  # appear here: flake `packages` are derivations, and a function would trip
  # `nix flake check`.
  power-menu = pkgs.callPackage ./power-menu { };
  network-menu = pkgs.callPackage ./network-menu { };
  bluetooth-menu = pkgs.callPackage ./bluetooth-menu { };
  audio-menu = pkgs.callPackage ./audio-menu { };
  clipboard-menu = pkgs.callPackage ./clipboard-menu { };

  # Do-not-disturb bar module + history menu (item 13)
  dnd = pkgs.callPackage ./dnd { };

  # Failed-units bar module + journal menu (item 14)
  failed-units = pkgs.callPackage ./failed-units { };

  # Keybind reference parsed from binds.lua (item 11)
  keybind-sheet = pkgs.callPackage ./keybind-sheet { };

  # Screenshot suite (item 15)
  screenshot = pkgs.callPackage ./screenshot { };

  # Project launcher / picker
  project-launcher = pkgs.callPackage ./project-launcher { };

  # Obsidian Sync headless CLI (`ob`)
  obsidian-headless = pkgs.callPackage ./obsidian-headless { };

  # Example custom package:
  # bootdevcli = pkgs.callPackage ./bootdevcli {};
}
