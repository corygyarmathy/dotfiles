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
    # xdg.enable = true;
    # programs.starship.enableBashIntegration = true;

    programs.starship = {
      enable = true;
      settings = pkgs.lib.importTOML ./starship.toml;
      enableBashIntegration = true;
    };
    # xdg.configFile."starship/starship.toml".source = ./starship.toml;

    home.packages = with pkgs; [
      starship # Shell prompt
    ];
  };
}
