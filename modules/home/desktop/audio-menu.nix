# Audio device menu - item 9 of docs/plans/desktop-design.md.
#
# The bar's pulseaudio module opens it on left click, and pavucontrol - the
# full mixer - moves to middle click. See packages/audio-menu.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.audio-menu;

  audio-menu = pkgs.audio-menu or (pkgs.callPackage ../../../packages/audio-menu { });
in
{
  options.cg.home.audio-menu.enable = lib.mkEnableOption "Audio sink and source menu";

  config = lib.mkIf cfg.enable {
    home.packages = [ audio-menu ];
  };
}
