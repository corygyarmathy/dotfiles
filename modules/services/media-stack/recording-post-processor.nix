{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cg.service.jellyfin-recording-post-processor;

  postProcessorScript = pkgs.writeShellScript "recording-post-processor" ''
    set -euo pipefail

    RECORDINGS_PATH="${cfg.recordingsPath}"
    LOG_FILE="/var/log/jellyfin/recording-post-processor.log"
    POST_PROCESS_SCRIPT="${cfg.postProcessScript}"
    CURRENT_TIME=$(date +%s)

    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Scanning for stitched recordings to post-process"

    # Find all *_stitched.ts files that haven't been processed yet
    while IFS= read -r -d $'\0' file; do
      # Skip if corresponding .mkv already exists
      BASE_PATH="''${file%_stitched.ts}"
      MKV_FILE="''${BASE_PATH}_stitched.mkv"
      
      if [[ -f "$MKV_FILE" ]]; then
        continue
      fi
      
      log "Found unprocessed file: $(basename "$file")"
      log "  Running post-processing..."
      
      # Run the post-processing script
      if "$POST_PROCESS_SCRIPT" "$file" >> "$LOG_FILE" 2>&1; then
        log "  Post-processing completed successfully"
      else
        log "  ERROR: Post-processing failed"
      fi
      
    done < <(find "$RECORDINGS_PATH" -name "*_stitched.ts" -print0)

    log "Scan completed"
  '';

in
{
  options.cg.service.jellyfin-recording-post-processor = {
    enable = lib.mkEnableOption "Jellyfin recording post-processor";

    recordingsPath = lib.mkOption {
      type = lib.types.path;
      description = "Path to Jellyfin recordings directory";
    };

    postProcessScript = lib.mkOption {
      type = lib.types.path;
      description = "Path to the post-processing script";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*:0/15";
      description = "When to scan for stitched files (systemd calendar format)";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jellyfin-recording-post-processor = {
      description = "Post-process stitched Jellyfin recordings";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${postProcessorScript}";
        User = "jellyfin";
        Group = "media";
      };
    };

    systemd.timers.jellyfin-recording-post-processor = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
      };
    };

    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d /var/log/jellyfin 0755 jellyfin media -"
    ];
  };
}
