#!/usr/bin/env bash
set -euo pipefail

RECORDING_PATH="$1"
LOG_FILE="/var/log/jellyfin/post-process.log"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Starting commercial cutting for: $RECORDING_PATH"

if [[ ! -f "$RECORDING_PATH" ]]; then
  log "ERROR: Recording file not found: $RECORDING_PATH"
  exit 1
fi

BASE_PATH="${RECORDING_PATH%.ts}"
EDL_FILE="${BASE_PATH}.edl"
CONCAT_FILE="${BASE_PATH}.concat"
FINAL_OUTPUT="${BASE_PATH}.mkv"

# Already processed?
if [[ -f "$FINAL_OUTPUT" ]]; then
  log "MKV file already exists, skipping processing"
  exit 0
fi

# --- Step 1: Run comskip ---
if [[ -f "$EDL_FILE" ]]; then
  log "EDL file already exists, skipping comskip"
else
  log "Running comskip..."
  if ! comskip --ini=/etc/comskip/comskip.ini "$RECORDING_PATH" >>"$LOG_FILE" 2>&1; then
    log "ERROR: comskip failed for $RECORDING_PATH"
    exit 1
  fi
fi

# No commercials detected = no EDL file, or empty EDL file
if [[ ! -f "$EDL_FILE" ]] || [[ ! -s "$EDL_FILE" ]]; then
  log "No commercials detected, converting to MKV without cutting"
  if ! ffmpeg -i "$RECORDING_PATH" -c copy -y "$FINAL_OUTPUT" >>"$LOG_FILE" 2>&1 </dev/null; then
    log "ERROR: Failed to convert to MKV"
    exit 1
  fi
  chown jellyfin:media "$FINAL_OUTPUT" 2>>"$LOG_FILE" || log "WARNING: Could not set ownership"
  rm -f "$RECORDING_PATH"
  log "Conversion completed (no commercials found)"
  exit 0
fi

# --- Step 2: Parse EDL into content segments ---
log "Parsing EDL file for content segments"

SEGMENTS_OUTPUT=$(edl-to-segments "$RECORDING_PATH" "$EDL_FILE" 2>"${BASE_PATH}.segments.stderr")
EXPECTED_DURATION=$(grep "EXPECTED_DURATION" "${BASE_PATH}.segments.stderr" | cut -d: -f2)
rm -f "${BASE_PATH}.segments.stderr"

if [[ -z "$SEGMENTS_OUTPUT" ]]; then
  log "ERROR: No content segments generated"
  exit 1
fi

log "Expected content duration: ${EXPECTED_DURATION}s"

# --- Step 3: Extract each content segment (stream copy, no re-encoding) ---
log "Extracting content segments..."
SEGMENT_FILES=()
SEGMENT_INDEX=0

while IFS=' ' read -r START END; do
  SEGMENT_FILE="${BASE_PATH}.seg${SEGMENT_INDEX}.ts"
  SEGMENT_FILES+=("$SEGMENT_FILE")

  log "  Segment $SEGMENT_INDEX: ${START}s - ${END}s"

  if ! ffmpeg -i "$RECORDING_PATH" \
    -ss "$START" -to "$END" \
    -c copy -y \
    "$SEGMENT_FILE" >>"$LOG_FILE" 2>&1 </dev/null; then
    log "ERROR: Failed to extract segment $SEGMENT_INDEX"
    # Clean up any segments we created
    for f in "${SEGMENT_FILES[@]}"; do rm -f "$f"; done
    exit 1
  fi

  SEGMENT_INDEX=$((SEGMENT_INDEX + 1))
done <<<"$SEGMENTS_OUTPUT"

log "Extracted $SEGMENT_INDEX content segments"

# --- Step 4: Concat segments (stream copy) ---
log "Concatenating segments..."

# Build concat demuxer file
: >"$CONCAT_FILE"
for f in "${SEGMENT_FILES[@]}"; do
  echo "file '$f'" >>"$CONCAT_FILE"
done

TEMP_OUTPUT="${BASE_PATH}.tmp.mkv"

if ! ffmpeg -f concat -safe 0 \
  -i "$CONCAT_FILE" \
  -c copy -y \
  "$TEMP_OUTPUT" >>"$LOG_FILE" 2>&1 </dev/null; then
  log "ERROR: Concatenation failed"
  rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
  for f in "${SEGMENT_FILES[@]}"; do rm -f "$f"; done
  exit 1
fi

# --- Step 5: Validate output duration ---
ACTUAL_DURATION=$(ffprobe -v quiet -print_format json -show_format "$TEMP_OUTPUT" |
  python3 -c "import sys, json; print(json.load(sys.stdin)['format']['duration'])")

log "Actual output duration: ${ACTUAL_DURATION}s"

DURATION_OK=$(python3 -c "
expected = float('$EXPECTED_DURATION')
actual = float('$ACTUAL_DURATION')
tolerance = expected * 0.02
print('yes' if abs(actual - expected) <= tolerance else 'no')
")

if [[ "$DURATION_OK" != "yes" ]]; then
  log "ERROR: Duration mismatch - expected: ${EXPECTED_DURATION}s, got: ${ACTUAL_DURATION}s"
  rm -f "$TEMP_OUTPUT" "$CONCAT_FILE"
  for f in "${SEGMENT_FILES[@]}"; do rm -f "$f"; done
  exit 1
fi

# --- Step 6: Finalise ---
mv "$TEMP_OUTPUT" "$FINAL_OUTPUT"
chown jellyfin:media "$FINAL_OUTPUT" 2>>"$LOG_FILE" || log "WARNING: Could not set ownership"

# Clean up
rm -f "$CONCAT_FILE"
for f in "${SEGMENT_FILES[@]}"; do rm -f "$f"; done
rm -f "$RECORDING_PATH"

log "Commercial cutting completed: $(basename "$FINAL_OUTPUT")"
