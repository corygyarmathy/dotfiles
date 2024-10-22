# The purpose of this file is to list all home-manager modules in one place
# This is then imported in the relevant systems home-manager file
# Each module is individually enabled as required for them to apply
{
  imports = [
    ./nvim
    ./starship
    ./waybar
    ./rofi
    ./alacritty.nix
    ./wezterm.nix
    ./hyprshade.nix # TODO: Include in hyprland.nix ?
    ./spotify-player.nix
    ./hyprland.nix
    ./hyprlock.nix
    ./ssh.nix
    ./sops-nix.nix
    ./stylix.nix
    ./tmux
    ./zellij
  ];
}
