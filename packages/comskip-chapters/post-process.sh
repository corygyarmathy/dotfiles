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

# Define paths - note we're working with .ts but outputting .mkv
BASE_PATH="${RECORDING_PATH%.ts}"
EDL_FILE="${BASE_PATH}.edl"
METADATA_FILE="${BASE_PATH}.ffmetadata"
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
    exit 0
  fi
fi

# Check if EDL was created (no commercials = no EDL)
if [[ ! -f "$EDL_FILE" ]]; then
  log "No commercials detected, skipping chapter embedding"
  exit 0
fi

log "EDL file found, processing chapters"

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

# Remux to MKV with chapters using ffmpeg
log "Converting to MKV and embedding chapters..."
if ! ffmpeg \
  -i "$RECORDING_PATH" \
  -i "$METADATA_FILE" \
  -map_metadata 1 \
  -map_chapters 1 \
  -codec copy \
  -y \
  "$TEMP_OUTPUT" >>"$LOG_FILE" 2>&1; then
  log "ERROR: ffmpeg conversion failed"
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

# Allow 5% size difference (MKV container overhead can vary)
ALLOWED_DIFF=$((ORIGINAL_SIZE / 20))

if [[ $SIZE_DIFF_ABS -gt $ALLOWED_DIFF ]]; then
  log "WARNING: Size mismatch - original: $ORIGINAL_SIZE, new: $NEW_SIZE, diff: $SIZE_DIFF"
  log "Size difference exceeds 5%, keeping original file"
  rm -f "$TEMP_OUTPUT" "$METADATA_FILE"
  exit 0
fi

# Move temp file to final output
log "Finalizing MKV file..."
if ! mv "$TEMP_OUTPUT" "$FINAL_OUTPUT"; then
  log "ERROR: Failed to create final MKV file"
  rm -f "$TEMP_OUTPUT" "$METADATA_FILE"
  exit 0
fi

# Clean up metadata file
rm -f "$METADATA_FILE"

# Restore proper ownership on MKV file
chown jellyfin:media "$FINAL_OUTPUT" 2>>"$LOG_FILE" || log "WARNING: Could not set ownership on MKV"

log "MKV conversion completed successfully"

# Optionally remove original TS file after successful conversion
# Uncomment the following lines if you want to automatically delete the .ts file:
# log "Removing original TS file..."
# rm -f "$RECORDING_PATH"
# log "Original TS file removed"

log "Post-processing completed successfully for: $RECORDING_PATH"
