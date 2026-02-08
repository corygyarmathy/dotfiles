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

    RECORDING_PATH="$1"
    LOG_FILE="/var/log/jellyfin/recording-stitcher.log"

    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Checking for segments: $RECORDING_PATH"

    # Extract base name (remove -N suffix if present)
    BASE_NAME=$(echo "$RECORDING_PATH" | sed -E 's/-[0-9]+\.ts$/.ts/')
    BASE_PATH="''${BASE_NAME%.ts}"

    # Find all segments matching this base name
    SEGMENTS=()
    while IFS= read -r -d $'\0' file; do
      SEGMENTS+=("$file")
    done < <(find "$(dirname "$RECORDING_PATH")" -name "$(basename "$BASE_PATH")*.ts" -print0 | sort -z)

    SEGMENT_COUNT=''${#SEGMENTS[@]}

    if [[ $SEGMENT_COUNT -eq 0 ]]; then
      log "ERROR: No segments found for $BASE_PATH"
      exit 1
    fi

    if [[ $SEGMENT_COUNT -eq 1 ]]; then
      log "Single segment, no stitching needed"
      exit 0
    fi

    log "Found $SEGMENT_COUNT segments to stitch"

    # Check if any segment was modified recently (still being written)
    STABILITY_SECONDS=${toString cfg.stabilityDelay}
    CURRENT_TIME=$(date +%s)

    for segment in "''${SEGMENTS[@]}"; do
      MODIFIED=$(stat -c %Y "$segment")
      AGE=$((CURRENT_TIME - MODIFIED))
      
      if [[ $AGE -lt $STABILITY_SECONDS ]]; then
        log "Segment $segment modified $AGE seconds ago (< $STABILITY_SECONDS), waiting for stability"
        exit 0
      fi
    done

    # Additional grace period to ensure no new segments appear
    GRACE_SECONDS=${toString cfg.graceDelay}
    FIRST_MODIFIED=$(stat -c %Y "''${SEGMENTS[0]}")
    GRACE_AGE=$((CURRENT_TIME - FIRST_MODIFIED))

    if [[ $GRACE_AGE -lt $((STABILITY_SECONDS + GRACE_SECONDS)) ]]; then
      log "Grace period not elapsed, waiting..."
      exit 0
    fi

    log "All segments stable, proceeding with stitching"

    # Generate concat file for ffmpeg
    CONCAT_FILE="''${BASE_PATH}.concat"
    OUTPUT_FILE="''${BASE_PATH}_stitched.ts"

    # Check if output already exists
    if [[ -f "$OUTPUT_FILE" ]]; then
      log "Stitched file already exists, skipping"
      exit 0
    fi

    # Create concat demuxer input file
    : > "$CONCAT_FILE"
    for segment in "''${SEGMENTS[@]}"; do
      echo "file '$segment'" >> "$CONCAT_FILE"
    done

    log "Created concat file with $SEGMENT_COUNT segments"

    # Stitch segments using concat demuxer (lossless, fast)
    TEMP_OUTPUT="''${OUTPUT_FILE}.tmp"

    log "Stitching segments (this may take a minute)..."
    if ! ${pkgs.ffmpeg}/bin/ffmpeg \
      -f concat \
      -safe 0 \
      -i "$CONCAT_FILE" \
      -c copy \
      -y \
      "$TEMP_OUTPUT" >> "$LOG_FILE" 2>&1; then
      log "ERROR: ffmpeg stitching failed"
      rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
      exit 1
    fi

    # Validate output
    if [[ ! -f "$TEMP_OUTPUT" ]]; then
      log "ERROR: Stitched file was not created"
      rm -f "$CONCAT_FILE"
      exit 1
    fi

    # Validate total duration approximately matches sum of segments
    EXPECTED_DURATION=0
    for segment in "''${SEGMENTS[@]}"; do
      DURATION=$(${pkgs.ffmpeg}/bin/ffprobe -v quiet -print_format json -show_format "$segment" | \
        ${pkgs.python3}/bin/python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")
      EXPECTED_DURATION=$(${pkgs.python3}/bin/python3 -c "print($EXPECTED_DURATION + $DURATION)")
    done

    ACTUAL_DURATION=$(${pkgs.ffmpeg}/bin/ffprobe -v quiet -print_format json -show_format "$TEMP_OUTPUT" | \
      ${pkgs.python3}/bin/python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")

    log "Expected duration: ''${EXPECTED_DURATION}s, Actual: ''${ACTUAL_DURATION}s"

    # Allow 2% tolerance (concat demuxer is lossless but timestamps may vary slightly)
    DURATION_DIFF=$(${pkgs.python3}/bin/python3 -c "print(abs($ACTUAL_DURATION - $EXPECTED_DURATION))")
    TOLERANCE=$(${pkgs.python3}/bin/python3 -c "print($EXPECTED_DURATION * 0.02)")

    if (( $(${pkgs.python3}/bin/python3 -c "print($DURATION_DIFF > $TOLERANCE)") )); then
      log "ERROR: Duration mismatch exceeds tolerance"
      log "Keeping original segments for safety"
      rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
      exit 1
    fi

    # Move to final output
    if ! mv "$TEMP_OUTPUT" "$OUTPUT_FILE"; then
      log "ERROR: Failed to move stitched file to final location"
      rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
      exit 1
    fi

    # Set ownership
    chown jellyfin:media "$OUTPUT_FILE" 2>> "$LOG_FILE" || log "WARNING: Could not set ownership"

    log "Stitching completed successfully: $OUTPUT_FILE"

    # Remove original segments
    log "Removing original segments..."
    for segment in "''${SEGMENTS[@]}"; do
      rm -f "$segment"
      log "Removed: $segment"
    done

    # Clean up concat file
    rm -f "$CONCAT_FILE"

    log "Segment stitching completed for: $BASE_PATH"
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
    # Path unit watches for .ts files in recordings directory
    systemd.paths.jellyfin-recording-stitcher = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = cfg.recordingsPath;
        Unit = "jellyfin-recording-stitcher@%f.service";
      };
    };

    # Template service processes specific recordings
    systemd.services."jellyfin-recording-stitcher@" = {
      description = "Stitch Jellyfin recording segments: %i";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${stitcherScript} ${cfg.recordingsPath}/%i";
        User = "jellyfin";
        Group = "media";

        # Restart on failure with exponential backoff
        Restart = "on-failure";
        RestartSec = "5m";
        StartLimitBurst = 3;
        StartLimitIntervalSec = "1h";
      };
    };

    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d /var/log/jellyfin 0755 jellyfin media -"
    ];
  };
}
