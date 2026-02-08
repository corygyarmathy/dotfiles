{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.jellyfin-recording-stitcher;

  stitcherScript = pkgs.writeShellScript "recording-stitcher" ''
    set -euo pipefail

    RECORDINGS_PATH="${cfg.recordingsPath}"
    LOG_FILE="/var/log/jellyfin/recording-stitcher.log"
    STABILITY_SECONDS=${toString cfg.stabilityDelay}
    GRACE_SECONDS=${toString cfg.graceDelay}
    CURRENT_TIME=$(date +%s)

    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Scanning for recording segments in $RECORDINGS_PATH"

    # Find all base recording names (without -N suffix)
    # We'll track which bases we've already seen to avoid duplicates
    declare -A processed_bases

    # Find all .ts files
    while IFS= read -r -d $'\0' file; do
      # Skip if this is already a stitched file
      if [[ "$file" == *"_stitched.ts" ]]; then
        continue
      fi
      
      # Extract base name (remove -N suffix)
      BASE_NAME=$(echo "$file" | sed -E 's/-[0-9]+\.ts$/.ts/')
      BASE_PATH="''${BASE_NAME%.ts}"
      
      # Skip if we've already processed this base
      if [[ -n "''${processed_bases[$BASE_PATH]:-}" ]]; then
        continue
      fi
      processed_bases[$BASE_PATH]=1
      
      # Find all segments for this base
      SEGMENTS=()
      while IFS= read -r -d $'\0' segment; do
        SEGMENTS+=("$segment")
      done < <(find "$RECORDINGS_PATH" -maxdepth 1 -name "$(basename "$BASE_PATH")*.ts" ! -name "*_stitched.ts" -print0 | sort -z)
      
      SEGMENT_COUNT=''${#SEGMENTS[@]}
      
      if [[ $SEGMENT_COUNT -eq 0 ]]; then
        continue
      fi
      
      if [[ $SEGMENT_COUNT -eq 1 ]]; then
        # Single segment, no stitching needed
        continue
      fi
      
      log "Found $SEGMENT_COUNT segments for $(basename "$BASE_PATH")"
      
      # Check if any segment was modified recently
      all_stable=true
      for segment in "''${SEGMENTS[@]}"; do
        MODIFIED=$(stat -c %Y "$segment")
        AGE=$((CURRENT_TIME - MODIFIED))
        
        if [[ $AGE -lt $STABILITY_SECONDS ]]; then
          log "  Segment $(basename "$segment") modified $AGE seconds ago, waiting for stability"
          all_stable=false
          break
        fi
      done
      
      if ! $all_stable; then
        continue
      fi
      
      # Check grace period
      FIRST_MODIFIED=$(stat -c %Y "''${SEGMENTS[0]}")
      GRACE_AGE=$((CURRENT_TIME - FIRST_MODIFIED))
      
      if [[ $GRACE_AGE -lt $((STABILITY_SECONDS + GRACE_SECONDS)) ]]; then
        log "  Grace period not elapsed for $(basename "$BASE_PATH"), waiting..."
        continue
      fi
      
      log "All segments stable for $(basename "$BASE_PATH"), proceeding with stitching"
      
      # Generate output filename
      CONCAT_FILE="''${BASE_PATH}.concat"
      OUTPUT_FILE="''${BASE_PATH}_stitched.ts"
      
      # Check if output already exists
      if [[ -f "$OUTPUT_FILE" ]]; then
        log "  Stitched file already exists, skipping"
        continue
      fi
      
      # Create concat demuxer input file
      : > "$CONCAT_FILE"
      for segment in "''${SEGMENTS[@]}"; do
        echo "file '$segment'" >> "$CONCAT_FILE"
      done
      
      log "  Created concat file with $SEGMENT_COUNT segments"
      
      # Stitch segments
      TEMP_OUTPUT="''${OUTPUT_FILE}.tmp"
      
      log "  Stitching segments..."
      if ! ${pkgs.ffmpeg}/bin/ffmpeg \
        -f concat \
        -safe 0 \
        -i "$CONCAT_FILE" \
        -c copy \
        -y \
        "$TEMP_OUTPUT" >> "$LOG_FILE" 2>&1; then
        log "  ERROR: ffmpeg stitching failed"
        rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
        continue
      fi
      
      # Validate output
      if [[ ! -f "$TEMP_OUTPUT" ]]; then
        log "  ERROR: Stitched file was not created"
        rm -f "$CONCAT_FILE"
        continue
      fi
      
      # Validate duration
      EXPECTED_DURATION=0
      for segment in "''${SEGMENTS[@]}"; do
        DURATION=$(${pkgs.ffmpeg}/bin/ffprobe -v quiet -print_format json -show_format "$segment" | \
          ${pkgs.python3}/bin/python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")
        EXPECTED_DURATION=$(${pkgs.python3}/bin/python3 -c "print($EXPECTED_DURATION + $DURATION)")
      done
      
      ACTUAL_DURATION=$(${pkgs.ffmpeg}/bin/ffprobe -v quiet -print_format json -show_format "$TEMP_OUTPUT" | \
        ${pkgs.python3}/bin/python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")
      
      log "  Expected duration: ''${EXPECTED_DURATION}s, Actual: ''${ACTUAL_DURATION}s"
      
      # Allow 2% tolerance
      DURATION_DIFF=$(${pkgs.python3}/bin/python3 -c "print(abs($ACTUAL_DURATION - $EXPECTED_DURATION))")
      TOLERANCE=$(${pkgs.python3}/bin/python3 -c "print($EXPECTED_DURATION * 0.02)")
      
      if (( $(${pkgs.python3}/bin/python3 -c "print($DURATION_DIFF > $TOLERANCE)") )); then
        log "  ERROR: Duration mismatch exceeds tolerance"
        log "  Keeping original segments for safety"
        rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
        continue
      fi
      
      # Move to final output
      if ! mv "$TEMP_OUTPUT" "$OUTPUT_FILE"; then
        log "  ERROR: Failed to move stitched file"
        rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
        continue
      fi
      
      # Set ownership
      chown jellyfin:media "$OUTPUT_FILE" 2>> "$LOG_FILE" || log "  WARNING: Could not set ownership"
      
      log "  Stitching completed: $(basename "$OUTPUT_FILE")"
      
      # Remove original segments
      log "  Removing original segments..."
      for segment in "''${SEGMENTS[@]}"; do
        rm -f "$segment"
        log "    Removed: $(basename "$segment")"
      done
      
      # Clean up concat file
      rm -f "$CONCAT_FILE"
      
    done < <(find "$RECORDINGS_PATH" -maxdepth 1 -name "*.ts" ! -name "*_stitched.ts" -print0)

    log "Scan completed"
  '';

in
{
  options.services.jellyfin-recording-stitcher = {
    enable = lib.mkEnableOption "Jellyfin recording segment stitcher";

    recordingsPath = lib.mkOption {
      type = lib.types.path;
      description = "Path to Jellyfin recordings directory";
    };

    stabilityDelay = lib.mkOption {
      type = lib.types.int;
      default = 600; # 10 minutes in seconds
      description = "Seconds to wait after last file modification before considering segments stable";
    };

    graceDelay = lib.mkOption {
      type = lib.types.int;
      default = 600; # 10 minutes in seconds
      description = "Additional seconds to wait after stability to ensure no new segments appear";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create a scanning service that finds and processes segments
    systemd.services.jellyfin-recording-stitcher = {
      description = "Stitch Jellyfin recording segments";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${stitcherScript}";
        User = "jellyfin";
        Group = "media";
      };
    };

    # Path unit triggers the scanning service when recordings directory changes
    systemd.paths.jellyfin-recording-stitcher = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = cfg.recordingsPath;
        # Coalesce multiple changes to avoid triggering too frequently
        TriggerLimitIntervalSec = "60s";
        TriggerLimitBurst = 5;
      };
    };

    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d /var/log/jellyfin 0755 jellyfin media -"
    ];
  };
}
