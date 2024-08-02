# alacritty.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    alacritty.enable = lib.mkEnableOption "enables alacritty";
  };

  config = lib.mkIf config.alacritty.enable {
    # Alacritty config (terminal editor)
    # TODO: split into separate module
    programs.alacritty = {
      enable = true;
      settings = {
        window = {
          opacity = lib.mkForce 0.85;
          padding.x = 10;
        };
      };
    };

    home.packages = with pkgs; [
      alacritty # Terminal emulator
    ];
  };
}
