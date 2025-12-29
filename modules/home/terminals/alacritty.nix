# alacritty.nix

{
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.alacritty.enable = lib.mkEnableOption "enables alacritty";
  };

  config = lib.mkIf config.cg.home.alacritty.enable {
    # Alacritty config (terminal editor)
    programs.alacritty = {
      enable = true;
      settings = {
        window = {
          opacity = lib.mkForce 0.85;
          padding.x = 10;
        };
        env = {
          TERM = "xterm-256color"; # Enable 24-bit colour
        };
      };
    };
  };
}
