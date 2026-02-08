# Jellyfin Live TV Recording Pipeline
#
# Manages the full lifecycle of Jellyfin live TV recordings:
#   1. Stitch  — Combine split recording segments into a single .ts file
#   2. Process — Detect and remove commercials using comskip → .mkv file
#   3. Cleanup — Delete recordings older than the retention period
#
# Each stage runs on its own systemd timer and communicates via file
# naming conventions:
#   - Raw segments:   "Show Name - 1.ts", "Show Name - 2.ts", ...
#   - Stitched:       "Show Name_stitched.ts"
#   - Processed:      "Show Name_stitched.mkv"
#
# Each stage is idempotent — it checks for output files before running
# and can safely be re-triggered without duplicating work.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cg.service.jellyfin-recordings;

  # --------------------------------------------------------------------------
  # Stage 1: Stitcher
  #
  # Jellyfin splits long live TV recordings into multiple .ts segments
  # (e.g., "Show - 1.ts", "Show - 2.ts"). This script finds related
  # segments, waits for them to stabilise (no more writes), then
  # concatenates them into a single "_stitched.ts" file using ffmpeg's
  # concat demuxer (stream copy — no re-encoding).
  # --------------------------------------------------------------------------
  stitcherScript = pkgs.writeShellScript "recording-stitcher" ''
    set -euo pipefail

    RECORDINGS_PATH="${cfg.recordingsPath}"
    LOG_FILE="/var/log/jellyfin/recording-stitcher.log"
    STABILITY_SECONDS=${toString cfg.stitching.stabilityDelay}
    GRACE_SECONDS=${toString cfg.stitching.graceDelay}
    CURRENT_TIME=$(date +%s)

    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Scanning for recording segments in $RECORDINGS_PATH"

    # Track which base recordings we've already seen to avoid duplicates
    declare -A processed_bases

    while IFS= read -r -d $'\0' file; do
      # Skip already-stitched files
      if [[ "$file" == *"_stitched.ts" ]]; then
        continue
      fi

      # Extract base name (strip the " - N" segment suffix)
      BASE_NAME=$(echo "$file" | sed -E 's/ - [0-9]+( - [0-9]+)?\.ts$/.ts/')
      BASE_PATH="''${BASE_NAME%.ts}"

      # Skip if we've already handled this base recording
      if [[ -n "''${processed_bases[$BASE_PATH]:-}" ]]; then
        continue
      fi
      processed_bases[$BASE_PATH]=1

      # Collect all segments for this base recording
      SEGMENTS=()
      while IFS= read -r -d $'\0' segment; do
        SEGMENTS+=("$segment")
      done < <(find "$(dirname "$BASE_PATH")" -maxdepth 1 \
        -name "$(basename "$BASE_PATH")*.ts" \
        ! -name "*_stitched.ts" \
        ! -name "*.tmp.ts" \
        -print0 | sort -z)

      SEGMENT_COUNT=''${#SEGMENTS[@]}

      # Nothing to do for 0 or 1 segments
      if [[ $SEGMENT_COUNT -le 1 ]]; then
        continue
      fi

      log "Found $SEGMENT_COUNT segments for $(basename "$BASE_PATH")"

      # Wait for all segments to stop being written to
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

      # Additional grace period to ensure no new segments appear
      FIRST_MODIFIED=$(stat -c %Y "''${SEGMENTS[0]}")
      GRACE_AGE=$((CURRENT_TIME - FIRST_MODIFIED))

      if [[ $GRACE_AGE -lt $((STABILITY_SECONDS + GRACE_SECONDS)) ]]; then
        log "  Grace period not elapsed for $(basename "$BASE_PATH"), waiting..."
        continue
      fi

      log "All segments stable for $(basename "$BASE_PATH"), stitching"

      CONCAT_FILE="''${BASE_PATH}.concat"
      OUTPUT_FILE="''${BASE_PATH}_stitched.ts"

      # Skip if already stitched
      if [[ -f "$OUTPUT_FILE" ]]; then
        log "  Stitched file already exists, skipping"
        continue
      fi

      # Build concat demuxer input
      : > "$CONCAT_FILE"
      for segment in "''${SEGMENTS[@]}"; do
        echo "file '$segment'" >> "$CONCAT_FILE"
      done

      log "  Stitching $SEGMENT_COUNT segments..."
      TEMP_OUTPUT="''${BASE_PATH}_stitched.tmp.ts"

      if ! ${pkgs.ffmpeg}/bin/ffmpeg \
        -f concat -safe 0 \
        -i "$CONCAT_FILE" \
        -c copy -y \
        "$TEMP_OUTPUT" >> "$LOG_FILE" 2>&1; then
        log "  ERROR: ffmpeg stitching failed"
        rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
        continue
      fi

      if [[ ! -f "$TEMP_OUTPUT" ]]; then
        log "  ERROR: Stitched file was not created"
        rm -f "$CONCAT_FILE"
        continue
      fi

      # Validate output duration (sum of segments vs stitched result)
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
      DURATION_OK=$(${pkgs.python3}/bin/python3 -c "
    expected = float($EXPECTED_DURATION)
    actual = float($ACTUAL_DURATION)
    print('yes' if abs(actual - expected) <= expected * 0.02 else 'no')
    ")

      if [[ "$DURATION_OK" != "yes" ]]; then
        log "  ERROR: Duration mismatch exceeds tolerance, keeping original segments"
        rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
        continue
      fi

      mv "$TEMP_OUTPUT" "$OUTPUT_FILE"
      chown jellyfin:media "$OUTPUT_FILE" 2>> "$LOG_FILE" || log "  WARNING: Could not set ownership"

      log "  Stitching completed: $(basename "$OUTPUT_FILE")"

      # Remove original segments
      for segment in "''${SEGMENTS[@]}"; do
        rm -f "$segment"
        log "    Removed: $(basename "$segment")"
      done

      rm -f "$CONCAT_FILE"

    done < <(find "$RECORDINGS_PATH" -name "*.ts" ! -name "*_stitched.ts" ! -name "*.tmp.ts" -print0)

    log "Stitch scan completed"
  '';

  # --------------------------------------------------------------------------
  # Stage 2: Commercial removal
  #
  # Finds *_stitched.ts files that don't yet have a corresponding .mkv,
  # then delegates to the comskip-cut package which:
  #   1. Runs comskip to generate an EDL (commercial break timestamps)
  #   2. Parses EDL into content segments (non-commercial portions)
  #   3. Extracts each segment with stream copy (no re-encoding)
  #   4. Concatenates segments into a single .mkv
  # --------------------------------------------------------------------------
  processorScript = pkgs.writeShellScript "recording-processor" ''
    set -euo pipefail

    RECORDINGS_PATH="${cfg.recordingsPath}"
    LOG_FILE="/var/log/jellyfin/recording-processor.log"
    POST_PROCESS="${pkgs.comskip-cut}/bin/post-process"
    CURRENT_TIME=$(date +%s)


    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Scanning for stitched recordings to process"

    # Find stitched files AND standalone .ts files without a matching .mkv
    while IFS= read -r -d $'\0' file; do
      # Determine the expected MKV output path
      if [[ "$file" == *"_stitched.ts" ]]; then
        MKV_FILE="''${file%_stitched.ts}_stitched.mkv"
      else
        MKV_FILE="''${file%.ts}.mkv"
      fi

      # Skip if already processed
      if [[ -f "$MKV_FILE" ]]; then
        continue
      fi

      # Skip files that are segments of a multi-part recording (stitcher handles these)
      if [[ "$(basename "$file")" =~ \ -\ [0-9]+\.ts$ ]]; then
        continue
      fi

      # Skip _stitched files still being written (just finished stitching)
      MODIFIED=$(stat -c %Y "$file")
      AGE=$((CURRENT_TIME - MODIFIED))
      if [[ $AGE -lt 1200 ]]; then
        continue
      fi

      # For non-stitched standalone files, also check that no related segments exist
      # (recording may still be in progress with Jellyfin writing new segments)
      if [[ "$file" != *"_stitched.ts" ]]; then
        BASE_PATH="''${file%.ts}"
        RELATED_SEGMENTS=$(find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$BASE_PATH") - *.ts" 2>/dev/null | head -1)
        if [[ -n "$RELATED_SEGMENTS" ]]; then
          continue
        fi
      fi

      log "Processing: $(basename "$file")"

      if "$POST_PROCESS" "$file" >> "$LOG_FILE" 2>&1; then
        log "  Completed successfully"
      else
        log "  ERROR: Post-processing failed (exit code: $?)"
      fi

    done < <(find "$RECORDINGS_PATH" -name "*.ts" ! -name "*.tmp.ts" -print0)

    log "Processing scan completed"
  '';

  # --------------------------------------------------------------------------
  # Stage 3: Cleanup
  #
  # Deletes recordings (and their intermediate files) older than the
  # configured retention period.
  # --------------------------------------------------------------------------
  cleanupScript = pkgs.writeShellScript "recording-cleanup" ''
    set -euo pipefail

    RECORDINGS_PATH="${cfg.recordingsPath}"
    RETENTION_DAYS=${toString cfg.cleanup.retentionDays}
    LOG_FILE="/var/log/jellyfin/recording-cleanup.log"

    log() {
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    log "Starting recording cleanup (retention: $RETENTION_DAYS days)"

    DELETED_COUNT=0

    while IFS= read -r -d $'\0' file; do
      BASE_PATH="''${file%.*}"
      BASE_NAME=$(basename "$BASE_PATH")

      log "Deleting: $BASE_NAME"
      rm -f "$file"

      ${lib.optionalString cfg.cleanup.cleanIntermediateFiles ''
        # Remove intermediate files generated by comskip and the pipeline
        rm -f "''${BASE_PATH}.edl"
        rm -f "''${BASE_PATH}.txt"
        rm -f "''${BASE_PATH}.log"
        rm -f "''${BASE_PATH}.vdr"
        rm -f "''${BASE_PATH}.concat"
        rm -f "''${BASE_PATH}.ffmetadata"
        rm -f "''${BASE_PATH}.logo.txt"
        # Remove any leftover segment files
        rm -f "''${BASE_PATH}".seg*.ts
      ''}

      DELETED_COUNT=$((DELETED_COUNT + 1))

    done < <(find "$RECORDINGS_PATH" \
      -type f \
      \( -name "*.ts" -o -name "*.mkv" \) \
      -mtime +$RETENTION_DAYS \
      -print0)

    if [[ $DELETED_COUNT -eq 0 ]]; then
      log "No recordings older than $RETENTION_DAYS days"
    else
      log "Cleanup completed: deleted $DELETED_COUNT recordings"
    fi
  '';

in
{
  options.cg.service.jellyfin-recordings = {
    enable = lib.mkEnableOption "Jellyfin recording post-processing pipeline";

    recordingsPath = lib.mkOption {
      type = lib.types.path;
      description = "Path to Jellyfin live TV recordings directory";
      example = "/srv/media/livetv";
    };

    stitching = {
      stabilityDelay = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = "Seconds to wait after last segment modification before stitching";
      };

      graceDelay = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = "Additional seconds after stability to ensure recording is complete";
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "*:0/15";
        description = "How often to scan for segments to stitch (systemd calendar format)";
      };
    };

    commercials = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to detect and remove commercials from stitched recordings";
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "*:0/15";
        description = "How often to scan for stitched files to process";
      };
    };

    cleanup = {
      retentionDays = lib.mkOption {
        type = lib.types.int;
        default = 14;
        description = "Days to keep recordings before automatic deletion";
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "03:00";
        description = "When to run cleanup (systemd calendar format)";
      };

      cleanIntermediateFiles = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Also delete .edl, .log, .concat and other intermediate files";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Shared log directory for all pipeline stages
    systemd.tmpfiles.rules = [
      "d /var/log/jellyfin 0755 jellyfin media -"
    ];

    # --- Stage 1: Stitcher ---
    systemd.services.jellyfin-recording-stitcher = {
      description = "Stitch Jellyfin recording segments";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = stitcherScript;
        User = "jellyfin";
        Group = "media";
      };
    };

    systemd.timers.jellyfin-recording-stitcher = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.stitching.schedule;
        Persistent = true;
      };
    };

    # --- Stage 2: Commercial removal ---
    systemd.services.jellyfin-recording-processor = lib.mkIf cfg.commercials.enable {
      description = "Remove commercials from stitched Jellyfin recordings";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = processorScript;
        User = "jellyfin";
        Group = "media";
      };
    };

    systemd.timers.jellyfin-recording-processor = lib.mkIf cfg.commercials.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.commercials.schedule;
        Persistent = true;
      };
    };

    # --- Stage 3: Cleanup ---
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
        OnCalendar = cfg.cleanup.schedule;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}
