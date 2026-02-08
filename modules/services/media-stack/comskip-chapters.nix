{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.cg.service.comskip-chapters;
in
{
  options.cg.service.comskip-chapters = {
    enable = mkEnableOption "comskip chapter embedding for Jellyfin recordings";

    package = mkOption {
      type = types.package;
      default = pkgs.comskip-chapters;
      defaultText = literalExpression "pkgs.comskip-chapters";
      description = "The comskip-chapters package to use";
    };

    logDirectory = mkOption {
      type = types.path;
      default = "/var/log/jellyfin";
      description = "Directory for post-processing logs";
    };

    scriptPath = mkOption {
      type = types.path;
      default = "/etc/jellyfin/comskip-post-process";
      description = "Path where Jellyfin expects the post-processing script";
    };

    user = mkOption {
      type = types.str;
      default = "jellyfin";
      description = "User that owns the log directory";
    };

    group = mkOption {
      type = types.str;
      default = "jellyfin";
      description = "Group that owns the log directory";
    };
  };

  config = mkIf cfg.enable {
    # Make the package available system-wide
    environment.systemPackages = [ cfg.package ];

    # Symlink the post-processing script to where Jellyfin expects it
    environment.etc."jellyfin/comskip-post-process" = {
      source = "${cfg.package}/bin/comskip-post-process";
      mode = "0755";
    };

    # Ensure log directory exists with correct permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.logDirectory} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
