#!/usr/bin/env bash
set -euo pipefail

RECORDING_PATH="$1"
LOG_FILE="/var/log/jellyfin/post-process.log"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Starting post-processing for: $RECORDING_PATH"

# Validate input
if [[ ! -f "$RECORDING_PATH" ]]; then
  log "ERROR: Recording file not found: $RECORDING_PATH"
  exit 0
fi

# Define paths
EDL_FILE="${RECORDING_PATH%.ts}.edl"
METADATA_FILE="${RECORDING_PATH%.ts}.ffmetadata"
TEMP_OUTPUT="${RECORDING_PATH%.ts}.tmp.ts"

# Run comskip to generate EDL file
log "Running comskip..."
if ! comskip "$RECORDING_PATH" >>"$LOG_FILE" 2>&1; then
  log "ERROR: comskip failed for $RECORDING_PATH"
  exit 0
fi

# Check if EDL was created (no commercials = no EDL)
if [[ ! -f "$EDL_FILE" ]]; then
  log "No commercials detected, skipping chapter embedding"
  exit 0
fi

log "comskip completed, EDL file created"

# Generate ffmpeg metadata from EDL
log "Generating chapter metadata..."
if ! edl-to-chapters "$RECORDING_PATH" "$EDL_FILE" >"$METADATA_FILE" 2>>"$LOG_FILE"; then
  log "ERROR: Failed to generate chapter metadata"
  rm -f "$METADATA_FILE"
  exit 0
fi

log "Chapter metadata generated"

# Get original file size for validation
ORIGINAL_SIZE=$(stat -c%s "$RECORDING_PATH")

# Remux with chapters using ffmpeg
log "Embedding chapters into video file..."
if ! ffmpeg \
  -fflags +genpts+igndts \
  -err_detect ignore_err \
  -i "$RECORDING_PATH" \
  -i "$METADATA_FILE" \
  -map_metadata 1 \
  -map_chapters 1 \
  -codec copy \
  -max_interleave_delta 0 \
  -avoid_negative_ts make_zero \
  -y \
  "$TEMP_OUTPUT" >>"$LOG_FILE" 2>&1; then
  log "ERROR: ffmpeg remux failed"
  rm -f "$TEMP_OUTPUT" "$METADATA_FILE"
  exit 0
fi

# Validate output file
if [[ ! -f "$TEMP_OUTPUT" ]]; then
  log "ERROR: Output file was not created"
  rm -f "$METADATA_FILE"
  exit 0
fi

NEW_SIZE=$(stat -c%s "$TEMP_OUTPUT")
SIZE_DIFF=$((ORIGINAL_SIZE - NEW_SIZE))
SIZE_DIFF_ABS=${SIZE_DIFF#-} # Absolute value

# Allow 1% size difference (metadata overhead)
ALLOWED_DIFF=$((ORIGINAL_SIZE / 100))

if [[ $SIZE_DIFF_ABS -gt $ALLOWED_DIFF ]]; then
  log "WARNING: Size mismatch - original: $ORIGINAL_SIZE, new: $NEW_SIZE, diff: $SIZE_DIFF"
  log "Size difference exceeds 1%, keeping original file"
  rm -f "$TEMP_OUTPUT" "$METADATA_FILE"
  exit 0
fi

# Atomically replace original file
log "Replacing original file with chaptered version..."
if ! mv "$TEMP_OUTPUT" "$RECORDING_PATH"; then
  log "ERROR: Failed to replace original file"
  rm -f "$TEMP_OUTPUT" "$METADATA_FILE"
  exit 0
fi

# Clean up metadata file
rm -f "$METADATA_FILE"

# Restore proper ownership
chown jellyfin:media "$RECORDING_PATH" 2>>"$LOG_FILE" || log "WARNING: Could not set ownership"

log "Post-processing completed successfully for: $RECORDING_PATH"
