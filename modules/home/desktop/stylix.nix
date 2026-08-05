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

    # NOTE: rose-pine-gtk-theme was removed from nixpkgs (depended on the
    # dropped gtk-engine-murrine/GTK 2). Stylix generates the GTK theme from
    # base16Scheme anyway, so no replacement is needed.
    home.packages = with pkgs; [
      rose-pine-icon-theme
    ];
  };
}
