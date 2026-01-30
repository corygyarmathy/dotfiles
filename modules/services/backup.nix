# modules/services/backup/default.nix
#
# Restic backup to Proton Drive via rclone
#
# Each host specifies which paths to back up. Restic handles:
# - Encryption (using password from sops)
# - Deduplication (only changed blocks uploaded)
# - Versioning (configurable retention policy)
#
# Rclone handles transport to Proton Drive.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.backup;
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.cg.service.backup = {
    enable = mkEnableOption "Restic backup to Proton Drive";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Paths to back up on this host";
      example = [
        "/srv/arr/sonarr"
        "/var/lib/jellyfin"
      ];
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [
        # Logs - can be regenerated, often large
        "*.log"
        "**/logs/**"
        "**/log/**"

        # Caches - can be regenerated
        "**/cache/**"
        "**/Cache/**"
        "**/.cache/**"

        # Temporary files
        "*.tmp"
        "*.temp"
        "**/tmp/**"

        # Lock files
        "*.lock"
        "**/*.lock"
      ];
      description = "Patterns to exclude from backup";
    };

    extraExclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional exclude patterns (added to defaults)";
    };

    schedule = mkOption {
      type = types.str;
      default = "03:00";
      description = "Time to run daily backup (24h format)";
    };

    rcloneRemote = mkOption {
      type = types.str;
      default = "proton";
      description = "Name of the rclone remote";
    };

    remotePath = mkOption {
      type = types.str;
      default = "backups/homelab/${config.networking.hostName}";
      description = "Path within the rclone remote for this host's backups";
    };

    retention = {
      daily = mkOption {
        type = types.int;
        default = 7;
        description = "Number of daily backups to keep";
      };
      weekly = mkOption {
        type = types.int;
        default = 4;
        description = "Number of weekly backups to keep";
      };
      monthly = mkOption {
        type = types.int;
        default = 3;
        description = "Number of monthly backups to keep";
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure rclone is available system-wide (for manual operations)
    environment.systemPackages = with pkgs; [
      rclone
      restic
    ];

    # Sops secrets
    sops.secrets."backups/restic/password" = {
      # Restic needs to read this
    };

    sops.secrets."backups/rclone-config" = {
      # Place rclone config where restic's systemd service can find it
      # The service runs as root, so /root/.config/rclone/ works
      path = "/root/.config/rclone/rclone.conf";
      mode = "0600";
    };

    # Restic backup job
    services.restic.backups.homelab = {
      # Create the repository if it doesn't exist
      initialize = true;

      # Repository location: rclone:<remote>:<path>
      repository = "rclone:${cfg.rcloneRemote}:${cfg.remotePath}";

      # Encryption password from sops
      passwordFile = config.sops.secrets."backups/restic/password".path;

      # What to back up
      paths = cfg.paths;
      exclude = cfg.exclude ++ cfg.extraExclude;

      # Schedule: daily at configured time
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true; # Run if missed (e.g., server was off)
        RandomizedDelaySec = "5m"; # Stagger backups slightly
      };

      # Retention policy: prune old snapshots after backup
      pruneOpts = [
        "--keep-daily ${toString cfg.retention.daily}"
        "--keep-weekly ${toString cfg.retention.weekly}"
        "--keep-monthly ${toString cfg.retention.monthly}"
      ];

      # Verify backup integrity periodically
      checkOpts = [ "--with-cache" ];

      # Backup options
      extraBackupArgs = [
        "--verbose"
        "--exclude-caches" # Exclude directories with CACHEDIR.TAG
      ];
    };
  };
}
