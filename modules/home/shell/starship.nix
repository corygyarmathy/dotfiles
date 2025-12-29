# nvim.nix

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.home.starship.enable = lib.mkEnableOption "enables starship";
  };

  config = lib.mkIf config.cg.home.starship.enable {
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
