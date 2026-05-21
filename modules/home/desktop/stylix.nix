# Stylix home-manager settings
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.stylix;
in
{
  options.cg.home.stylix.enable = lib.mkEnableOption "Stylix home-manager theming";

  # TODO: investigate enabling this when the main cg.stylix option is enabled
  config = lib.mkIf cfg.enable {
    stylix.targets = {
      waybar.enable = false; # Custom config
      vim.enable = false; # Custom config
      hyprlock.enable = false; # Custom config
      starship.enable = false; # Custom config
    };

    home.packages = with pkgs; [
      # TODO: are these needed?
      rose-pine-gtk-theme
      rose-pine-icon-theme
    ];
  };
}
