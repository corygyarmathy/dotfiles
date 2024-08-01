# nvim.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    starship.enable = lib.mkEnableOption "enables starship";
  };

  config = lib.mkIf config.nvim.enable {
    # Starship configuration
    xdg.enable = true;
    programs.starship.enableBashIntegration = true;

    xdg.configFile."starship.toml".source = ./starship.toml;
    programs.starship.enable = true;

    home.packages = with pkgs; [
      starship # Shell prompt
    ];
  };
}
