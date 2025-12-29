# NixOS modules index
# Each module provides a cg.<name>.enable option
{
  imports = [
    ./hyprland.nix
    ./gnome.nix
    ./nvidia.nix
    ./stylix.nix
    ./ddc.nix
    ./ergodox.nix
    ./sops-nix.nix
  ];
}
