# Clipboard history - item 10 of docs/plans/desktop-design.md.
#
# Two daemons and one menu. cliphist stores the history (skipping offers that
# carry the secret hint, which is what makes it safe to keep password-manager
# fields near the clipboard); wl-clip-persist keeps the current selection
# alive beyond the window that copied it - the papercut that fires several
# times a day. The menu is SUPER+SHIFT+V. See packages/clipboard-menu.
#
# History length is cliphist's own default (-max-items 500, which the
# home-manager service sets) and has not been argued with; a number nobody
# has a reason for is a number nobody should choose.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.clipboard;

  clipboard-menu = pkgs.clipboard-menu or (pkgs.callPackage ../../../packages/clipboard-menu { });
in
{
  options.cg.home.clipboard.enable =
    lib.mkEnableOption "Clipboard history (cliphist + wl-clip-persist)";

  config = lib.mkIf cfg.enable {
    services.cliphist.enable = true;
    services.wl-clip-persist.enable = true;

    # The menu is the same toggle's other half: clipboard history without a
    # way to recall it is a store that only grows.
    home.packages = [ clipboard-menu ];
  };
}
