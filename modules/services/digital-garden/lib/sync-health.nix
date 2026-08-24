# Exports the "is Obsidian Sync still completing cycles?" positive signal as a
# node_exporter textfile metric. See the header of digital-garden.nix and the
# DigitalGardenSyncStale alert for why this exists.
#
# The obsidian-headless client tees its console output to
# <stateDir>/obsidian/obsidian-headless/sync/<vault>/sync.log, one timestamped
# line per event, and logs "Fully synced" only after a cycle that connected to
# the server and reached steady state - about every 30s when healthy. The age
# of the newest such line is therefore a positive signal that sync is working
# (as opposed to a guess like "the vault mtime is old"), and exporting it lets
# Prometheus alert on its absence.
#
# Fail-open: when there is no "Fully synced" line yet (sync not set up, or a
# future obsidian-headless moved the message), nothing is emitted, so the alert
# cannot fire on a guess. The reason is written to the journal instead.
{
  pkgs,
  lib,
  stateDir,
  hostName,
}:
pkgs.writeShellApplication {
  name = "digital-garden-sync-health";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
  ];
  text = ''
    # Overridable so the check in checks/ can point these at a fixture.
    METRICS_DIR="''${DIGITAL_GARDEN_METRICS_DIR:-/var/lib/prometheus-node-exporter}"
    SYNC_LOG_DIR="''${DIGITAL_GARDEN_SYNC_DIR:-${stateDir}/obsidian/obsidian-headless/sync}"
    METRICS_FILE="$METRICS_DIR/digital_garden_sync.prom"
    HOST="${hostName}"

    mkdir -p "$METRICS_DIR"

    latest=0
    found=0
    if [ -d "$SYNC_LOG_DIR" ]; then
      for log in "$SYNC_LOG_DIR"/*/sync.log; do
        [ -e "$log" ] || continue
        # tac + quit-on-first-match finds the last "Fully synced" line without
        # reading the whole (append-only, ever-growing) log. The line looks
        # like "[2026-08-24T12:34:56.789Z] Fully synced".
        ts=$(tac "$log" 2>/dev/null | sed -nE '/^\[[^]]+\] Fully synced$/{s/^\[([^]]+)\].*/\1/p;q}' || true)
        if [ -n "$ts" ]; then
          epoch=$(date -d "$ts" +%s 2>/dev/null || true)
          if [ -n "$epoch" ]; then
            found=1
            if [ "$epoch" -gt "$latest" ]; then
              latest=$epoch
            fi
          fi
        fi
      done
    fi

    if [ "$found" -eq 1 ]; then
      cat > "$METRICS_FILE.tmp" <<EOF
# HELP digital_garden_sync_last_ok_timestamp_seconds Unix timestamp of the last completed Obsidian Sync cycle
# TYPE digital_garden_sync_last_ok_timestamp_seconds gauge
digital_garden_sync_last_ok_timestamp_seconds{host="$HOST"} $latest
EOF
      mv "$METRICS_FILE.tmp" "$METRICS_FILE"
    else
      # Fail open: no data yet, or the log format moved under us. Emit nothing
      # so the alert cannot fire on a guess; the journal carries the reason for
      # whoever looks.
      echo "digital-garden-sync-health: no 'Fully synced' timestamp found under $SYNC_LOG_DIR" >&2
      rm -f "$METRICS_FILE"
    fi
  '';
}
