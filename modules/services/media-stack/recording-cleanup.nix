{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cg.service.jellyfin-recording-cleanup;

  cleanupScript = pkgs.writeShellScript "recording-cleanup" ''
    set -euo pipefail

    RECORDINGS_PATH="${cfg.recordingsPath}"
    RETENTION_DAYS=${toString cfg.retentionDays}
    LOG_FILE="/var/log/jellyfin/recording-cleanup.log"

    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Starting recording cleanup (retention: $RETENTION_DAYS days)"

    # Find recordings older than retention period
    DELETED_COUNT=0

    # Find .ts and .mkv files older than retention
    while IFS= read -r -d $'\0' file; do
      BASE_PATH="''${file%.*}"
      BASE_NAME=$(basename "$BASE_PATH")
      
      log "Deleting recording: $BASE_NAME"
      
      # Delete the main recording file
      rm -f "$file"
      
      ${lib.optionalString cfg.cleanIntermediateFiles ''
        # Delete associated intermediate files
        rm -f "''${BASE_PATH}.edl"       # Comskip commercial detection
        rm -f "''${BASE_PATH}.txt"       # Comskip detailed log
        rm -f "''${BASE_PATH}.log"       # Comskip summary
        rm -f "''${BASE_PATH}.vdr"       # Comskip VDR format
        rm -f "''${BASE_PATH}.filter"    # FFmpeg filter script
        rm -f "''${BASE_PATH}.concat"    # FFmpeg concat file
        rm -f "''${BASE_PATH}.ffmetadata" # Temp metadata (shouldn't exist but cleanup anyway)
      ''}
      
      DELETED_COUNT=$((DELETED_COUNT + 1))
      log "Deleted: $BASE_NAME (and associated files)"
      
    done < <(find "$RECORDINGS_PATH" \
      -type f \
      \( -name "*.ts" -o -name "*.mkv" \) \
      -mtime +$RETENTION_DAYS \
      -print0)

    if [[ $DELETED_COUNT -eq 0 ]]; then
      log "No recordings found older than $RETENTION_DAYS days"
    else
      log "Cleanup completed: deleted $DELETED_COUNT recordings"
    fi
  '';

in
{
  options.cg.service.jellyfin-recording-cleanup = {
    enable = lib.mkEnableOption "Jellyfin recording retention cleanup";

    recordingsPath = lib.mkOption {
      type = lib.types.path;
      description = "Path to Jellyfin recordings directory";
    };

    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = "Number of days to retain recordings before deletion";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "When to run cleanup (systemd calendar format, e.g., 'daily', '03:00', 'weekly')";
    };

    cleanIntermediateFiles = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to also delete intermediate files (.edl, .txt, .log, etc.)";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jellyfin-recording-cleanup = {
      description = "Clean up old Jellyfin recordings";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = cleanupScript;
        User = "jellyfin";
        Group = "media";
      };
    };

    systemd.timers.jellyfin-recording-cleanup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true; # Run missed timers on boot
        RandomizedDelaySec = "30m"; # Randomize to avoid spike
      };
    };

    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d /var/log/jellyfin 0755 jellyfin media -"
    ];
  };
}
