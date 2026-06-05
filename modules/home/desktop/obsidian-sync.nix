# Setup continuous Obsidian sync service, using obsidian-headless package (Obsidian CLI tool)
#
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.cg.home.obsidian-sync;

  # Import the package
  obsidian-headless = self.packages.${pkgs.system}.obsidian-headless;

in
{
  options.cg.home.obsidian-sync = {
    enable = lib.mkEnableOption "Start background sync of Obsidian library";
  };

  config = lib.mkIf cfg.enable {
    # Add the packages to path
    home.packages = [ obsidian-headless ]; # `ob` on PATH for the one-time setup

    systemd.user.services.obsidian-sync = {
      Unit = {
        Description = "Obsidian headless continuous sync";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "${lib.getExe obsidian-headless} sync --continuous --path %h/git/personal-notes";
        Restart = "on-failure";
        RestartSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
