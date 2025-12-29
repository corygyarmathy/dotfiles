# Home-manager modules index
# Each module provides a cg.home.<name>.enable option
{
  imports = [
    # Shell
    ./shell/starship.nix
    ./shell/zellij.nix
    ./shell/bash.nix

    # Terminals
    ./terminals/alacritty.nix
    ./terminals/ghostty.nix

    # Desktop
    ./desktop/hyprland.nix
    ./desktop/hyprlock.nix
    ./desktop/hyprsunset.nix
    ./desktop/waybar.nix
    ./desktop/rofi.nix
    ./desktop/stylix.nix

    # Development
    ./development/nvim.nix
    ./development/git.nix
    ./development/direnv.nix
    ./development/ssh.nix

    # Media
    ./media/spotify-player.nix

    # Security
    ./security/sops-nix.nix
  ];
}
