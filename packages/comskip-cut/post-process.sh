#!/usr/bin/env bash
set -euo pipefail

RECORDING_PATH="$1"
LOG_FILE="/var/log/jellyfin/post-process.log"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Starting commercial cutting for: $RECORDING_PATH"

# Validate input
if [[ ! -f "$RECORDING_PATH" ]]; then
  log "ERROR: Recording file not found: $RECORDING_PATH"
  exit 1
fi

# Define paths
BASE_PATH="${RECORDING_PATH%.ts}"
EDL_FILE="${BASE_PATH}.edl"
FILTER_FILE="${BASE_PATH}.filter"
TEMP_OUTPUT="${BASE_PATH}.tmp.mkv"
FINAL_OUTPUT="${BASE_PATH}.mkv"

# Check if MKV already exists (already processed)
if [[ -f "$FINAL_OUTPUT" ]]; then
  log "MKV file already exists, skipping processing"
  exit 0
fi

# Check if EDL already exists
if [[ -f "$EDL_FILE" ]]; then
  log "EDL file already exists, skipping comskip"
else
  # Run comskip to generate EDL file
  log "Running comskip..."
  if ! comskip "$RECORDING_PATH" >>"$LOG_FILE" 2>&1; then
    log "ERROR: comskip failed for $RECORDING_PATH"
    exit 1
  fi
fi

# Check if EDL was created (no commercials = no EDL)
if [[ ! -f "$EDL_FILE" ]]; then
  log "No commercials detected, copying to MKV without cutting"
  if ! ffmpeg -i "$RECORDING_PATH" -c copy -y "$FINAL_OUTPUT" >>"$LOG_FILE" 2>&1; then
    log "ERROR: Failed to convert to MKV"
    exit 1
  fi
  chown jellyfin:media "$FINAL_OUTPUT" 2>>"$LOG_FILE" || log "WARNING: Could not set ownership"
  rm -f "$RECORDING_PATH"
  log "Conversion completed (no commercials found)"
  exit 0
fi

log "EDL file found, generating cut segments"

# Generate ffmpeg filter script from EDL
# Captures expected duration from stderr
FILTER_OUTPUT=$(edl-to-segments "$RECORDING_PATH" "$EDL_FILE" 2>&1)
FILTER_SCRIPT=$(echo "$FILTER_OUTPUT" | grep -v "EXPECTED_DURATION")
EXPECTED_DURATION=$(echo "$FILTER_OUTPUT" | grep "EXPECTED_DURATION" | cut -d: -f2)

if [[ -z "$FILTER_SCRIPT" ]]; then
  log "ERROR: Failed to generate filter script"
  exit 1
fi

log "Filter script generated, expected duration: ${EXPECTED_DURATION}s"

# Get original duration for comparison
ORIGINAL_DURATION=$(ffprobe -v quiet -print_format json -show_format "$RECORDING_PATH" |
  python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")

log "Original duration: ${ORIGINAL_DURATION}s"

# Cut commercials using filter_complex
log "Cutting commercials (this may take a few minutes)..."
if ! ffmpeg \
  -i "$RECORDING_PATH" \
  -filter_complex "$FILTER_SCRIPT" \
  -map "[outv]" -map "[outa]" \
  -c:v libx264 -preset ultrafast -crf 23 \
  -c:a copy \
  -y \
  "$TEMP_OUTPUT" >>"$LOG_FILE" 2>&1; then
  log "ERROR: ffmpeg cutting failed"
  rm -f "$TEMP_OUTPUT"
  exit 1
fi

# Validate output file
if [[ ! -f "$TEMP_OUTPUT" ]]; then
  log "ERROR: Output file was not created"
  exit 1
fi

# Validate output duration matches expected
ACTUAL_DURATION=$(ffprobe -v quiet -print_format json -show_format "$TEMP_OUTPUT" |
  python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")

log "Actual output duration: ${ACTUAL_DURATION}s"

# Allow 1% tolerance for duration mismatch (encoding can cause slight variations)
DURATION_DIFF=$(python3 -c "print(abs(float('$ACTUAL_DURATION') - float('$EXPECTED_DURATION')))")
TOLERANCE=$(python3 -c "print(float('$EXPECTED_DURATION') * 0.01)")

if (($(python3 -c "print($DURATION_DIFF > $TOLERANCE)"))); then
  log "ERROR: Duration mismatch - expected: ${EXPECTED_DURATION}s, got: ${ACTUAL_DURATION}s"
  log "Keeping original file for safety"
  rm -f "$TEMP_OUTPUT"
  exit 1
fi

# Move temp file to final output
log "Finalizing MKV file..."
if ! mv "$TEMP_OUTPUT" "$FINAL_OUTPUT"; then
  log "ERROR: Failed to create final MKV file"
  rm -f "$TEMP_OUTPUT"
  exit 1
fi

# Restore proper ownership
chown jellyfin:media "$FINAL_OUTPUT" 2>>"$LOG_FILE" || log "WARNING: Could not set ownership on MKV"

log "Commercial cutting completed successfully"

# Remove original TS file after successful cutting
log "Removing original TS file..."
rm -f "$RECORDING_PATH"
log "Original TS file removed"

log "Post-processing completed successfully for: $RECORDING_PATH"
