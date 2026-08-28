# modules/services/backup.nix
#
# Restic backup with multiple repository targets
#
# Each host specifies which paths to back up. The module creates a
# separate restic backup job for each configured repository, enabling
# 3-2-1 backup strategies (local cross-server + offsite cloud).
#
# Restic handles:
# - Encryption (using password from sops)
# - Deduplication (only changed blocks uploaded)
# - Versioning (configurable retention policy)
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
    mapAttrs
    mapAttrsToList
    any
    hasPrefix
    filterAttrs
    ;

  # Check if any configured repository uses rclone
  hasRcloneRepo = any (repo: hasPrefix "rclone:" repo.repository) (
    mapAttrsToList (_: v: v) cfg.repositories
  );

  hasSftpRepo = any (repo: hasPrefix "sftp:" repo.repository) (
    mapAttrsToList (_: v: v) cfg.repositories
  );

  # Every fleet machine with a reserved address; the laptop has none and is
  # never an SFTP backup target.
  fleetAddresses = mapAttrsToList (_: host: host.address) (
    filterAttrs (_: host: host ? address) config.cg.fleet.hosts
  );

  # Submodule type for individual repository targets
  repositoryModule = types.submodule {
    options = {
      repository = mkOption {
        type = types.str;
        description = ''
          Restic repository URL. Supports any restic backend:
          - sftp:user@host:/path (cross-server via SSH)
          - rclone:remote:path (cloud via rclone)
          - /local/path (local directory)
          - rest:http://host:port/ (restic REST server)
        '';
        example = "sftp:coryg@10.20.2.130:/srv/backups/homelab01";
      };

      schedule = mkOption {
        type = types.str;
        default = cfg.schedule;
        description = "Time to run daily backup for this repo (24h format). Defaults to the global schedule.";
      };

      retention = {
        daily = mkOption {
          type = types.int;
          default = cfg.retention.daily;
          description = "Number of daily backups to keep. Defaults to global retention.";
        };
        weekly = mkOption {
          type = types.int;
          default = cfg.retention.weekly;
          description = "Number of weekly backups to keep. Defaults to global retention.";
        };
        monthly = mkOption {
          type = types.int;
          default = cfg.retention.monthly;
          description = "Number of monthly backups to keep. Defaults to global retention.";
        };
      };
    };
  };

  # Script that writes backup metrics for Prometheus node_exporter textfile collector
  backupMetricsScript =
    name:
    pkgs.writeShellScript "restic-backup-metrics-${name}" ''
        METRICS_DIR="/var/lib/prometheus-node-exporter"
        METRICS_FILE="$METRICS_DIR/restic_backup_${name}.prom"
        mkdir -p "$METRICS_DIR"

        # SERVICE_RESULT is set by systemd for ExecStopPost commands
        if [ "$SERVICE_RESULT" = "success" ]; then
          SUCCESS=1
        else
          SUCCESS=0
        fi

        cat > "$METRICS_FILE" <<EOF
      # HELP restic_backup_last_run_timestamp_seconds Unix timestamp of last backup completion
      # TYPE restic_backup_last_run_timestamp_seconds gauge
      restic_backup_last_run_timestamp_seconds{job="${name}",host="${config.networking.hostName}"} $(date +%s)
      # HELP restic_backup_last_run_success Whether the last backup succeeded (1=success, 0=failure)
      # TYPE restic_backup_last_run_success gauge
      restic_backup_last_run_success{job="${name}",host="${config.networking.hostName}"} $SUCCESS
      EOF
    '';
in
{
  # Reads config.cg.fleet, so it declares it - see modules/nixos/fleet.nix.
  imports = [ ../nixos/fleet.nix ];

  options.cg.service.backup = {
    enable = mkEnableOption "Restic backup to defined repositories";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Paths to back up on this host (shared across all repositories)";
      example = [
        "/srv/arr"
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
      description = "Additional exclude patterns (added to default excluded)";
    };

    schedule = mkOption {
      type = types.str;
      default = "03:00";
      description = "Time to run daily backups (24h format)";
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

    repositories = mkOption {
      type = types.attrsOf repositoryModule;
      default = { };
      description = ''
        Named backup repositories. Each entry creates a separate restic
        backup job targeting that repository. All jobs back up the same
        paths with the same excludes.
      '';
      example = {
        cross-server = {
          repository = "sftp:coryg@10.20.2.130:/srv/backups/homelab01";
          schedule = "02:30";
        };
        gdrive = {
          repository = "rclone:gdrive:backups/homelab/homelab01";
          schedule = "03:00";
        };
      };
    };

    incomingPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Local path where this host receives backups from other hosts.
        The module creates this directory with correct permissions.
        Set to null if this host doesn't receive cross-server backups.
      '';
      example = "/srv/backups/homelab02";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ restic ] ++ lib.optional hasRcloneRepo rclone;

    assertions = lib.optionals hasSftpRepo [
      {
        assertion = config.cg.ssh-hardening.enable;
        message = "SFTP backup repositories require SSH hardening module to be enabled (for SSH access)";
      }
    ];

    # Restic encryption password (shared across all repos)
    sops.secrets."backups/restic/password" = { };

    # Rclone config - only provisioned if any repo uses rclone
    sops.secrets."backups/rclone-config" = mkIf hasRcloneRepo {
      path = "/root/.config/rclone/rclone.conf";
      mode = "0600";
    };

    # SSH key for SFTP-based backups (restic runs as root)
    sops.secrets."backups/ssh/private-key" = mkIf hasSftpRepo {
      path = "/root/.ssh/id_backup";
      mode = "0600";
    };

    # Configure root's SSH to use the backup key and accept host keys for the
    # fleet's own machines. Named one at a time rather than as a subnet glob:
    # every address here is one this flake already knows, and a glob offers the
    # backup key to whatever else happens to answer on the LAN.
    programs.ssh.extraConfig = mkIf hasSftpRepo ''
      Host ${lib.concatStringsSep " " fleetAddresses}
        IdentityFile /root/.ssh/id_backup
        StrictHostKeyChecking accept-new
    '';

    # Generate a restic backup job for each configured repository
    services.restic.backups = mapAttrs (name: repo: {
      initialize = true;
      repository = repo.repository;
      passwordFile = config.sops.secrets."backups/restic/password".path;

      # What to back up
      paths = cfg.paths;
      exclude = cfg.exclude ++ cfg.extraExclude;

      timerConfig = {
        Persistent = true; # Run if missed (e.g., server was off)
        RandomizedDelaySec = "5m"; # Stagger backups slightly
        OnCalendar = repo.schedule;
      };

      pruneOpts = [
        "--keep-daily ${toString repo.retention.daily}"
        "--keep-weekly ${toString repo.retention.weekly}"
        "--keep-monthly ${toString repo.retention.monthly}"
      ];

      # Verify backup integrity periodically
      checkOpts = [ "--with-cache" ];

      # Backup options
      extraBackupArgs = [
        "--verbose"
        "--exclude-caches" # Exclude directories with CACHEDIR.TAG
      ];

      # Write metrics on completion
      backupCleanupCommand = "${backupMetricsScript name}";

    }) cfg.repositories;

    systemd.tmpfiles.rules = lib.optionals (cfg.incomingPath != null) [
      "d ${builtins.dirOf cfg.incomingPath} 0755 root root -"
      "d ${cfg.incomingPath} 0700 coryg users -"
    ];
  };
}
