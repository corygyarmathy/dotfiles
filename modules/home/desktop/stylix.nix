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

    # An icon theme that is actually installed, and actually selected.
    #
    # Before this, `home.packages` carried rose-pine-icon-theme and nothing
    # ever pointed GTK at it, so the icon theme in force was gsettings'
    # default of Adwaita - which is not installed either. GTK fell back to
    # hicolor, which has almost nothing in it, and the failure surfaced two
    # layers away: udiskie asks for `drive-removable-media`, does not find it,
    # and returns the literal string "not-available" (udiskie/tray.py), which
    # waybar's tray then cannot find either and logs as its own error. The
    # tray icon was simply missing.
    #
    # Papirus rather than Adwaita because stylix recolours Papirus to the
    # base16 scheme, so the icons arrive on the same palette as everything
    # else lib/kanagawa-wave.nix feeds - and because it carries the full
    # freedesktop names, which is what a tray asks for by convention.
    stylix.icons = {
      enable = true;
      package = pkgs.papirus-icon-theme;
      dark = "Papirus-Dark";
      light = "Papirus-Light";
    };
  };
}
