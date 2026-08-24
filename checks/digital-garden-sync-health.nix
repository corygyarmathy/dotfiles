# The sync-health exporter parses obsidian-headless's sync.log for the last
# "Fully synced" timestamp. Its whole purpose is a positive signal for "sync is
# still working", and its characteristic failure is silent: if the log format
# moves under us (a proprietary, auto-updating package), the exporter finds
# nothing and quietly stops exporting, and the alert quietly stops firing. This
# check runs the real script against a fixture, so a change to the format, or a
# break in the script's parsing, fails here rather than in production.
{ pkgs, lib }:
let
  syncHealth = import ../modules/services/digital-garden/lib/sync-health.nix {
    inherit pkgs lib;
    stateDir = "/var/lib/digital-garden";
    hostName = "test";
  };

  # The last "Fully synced" line is 2026-08-01T00:00:01Z.
  logWithSync = pkgs.writeText "sync.log" ''
    [2026-08-01T00:00:00.000Z] Downloading notes/a.md
    [2026-08-01T00:00:01.000Z] Fully synced
    [2026-08-02T00:00:00.000Z] Waiting to connect to server
  '';

  # Newer than logWithSync, for the "newest vault wins" case.
  logNewer = pkgs.writeText "sync.log" ''
    [2026-08-03T00:00:00.000Z] Fully synced
  '';

  # No "Fully synced" line at all.
  logNoSync = pkgs.writeText "sync.log" ''
    [2026-08-01T00:00:00.000Z] Waiting to connect to server
  '';
in
pkgs.runCommand "check-digital-garden-sync-health" {
  nativeBuildInputs = [ syncHealth ];
} ''
  set -euo pipefail
  fixture=$(mktemp -d)
  metrics=$(mktemp -d)
  metric="$metrics/digital_garden_sync.prom"

  # The exporter globs <syncDir>/*/sync.log, mirroring the real layout
  # <stateDir>/obsidian/obsidian-headless/sync/<vaultId>/sync.log.
  # Case 1: a "Fully synced" line becomes a metric with the right epoch.
  mkdir -p "$fixture/sync/vault-abc"
  cp ${logWithSync} "$fixture/sync/vault-abc/sync.log"
  DIGITAL_GARDEN_SYNC_DIR="$fixture/sync" DIGITAL_GARDEN_METRICS_DIR="$metrics" digital-garden-sync-health
  expected=$(date -d '2026-08-01T00:00:01.000Z' +%s)
  got=$(sed -nE 's/^digital_garden_sync_last_ok_timestamp_seconds\{host="test"\} ([0-9]+)$/\1/p' "$metric")
  test "$got" = "$expected" || { echo "case 1: expected $expected, got '$got'" >&2; exit 1; }

  # Case 2: the newest "Fully synced" across vaults wins.
  mkdir -p "$fixture/sync/vault-newer"
  cp ${logNewer} "$fixture/sync/vault-newer/sync.log"
  DIGITAL_GARDEN_SYNC_DIR="$fixture/sync" DIGITAL_GARDEN_METRICS_DIR="$metrics" digital-garden-sync-health
  expected=$(date -d '2026-08-03T00:00:00.000Z' +%s)
  got=$(sed -nE 's/^digital_garden_sync_last_ok_timestamp_seconds\{host="test"\} ([0-9]+)$/\1/p' "$metric")
  test "$got" = "$expected" || { echo "case 2: expected $expected, got '$got'" >&2; exit 1; }

  # Case 3: no "Fully synced" line -> fail open, no metric file at all.
  rm -rf "$fixture" "$metrics"
  mkdir -p "$fixture/sync/vault-abc"
  cp ${logNoSync} "$fixture/sync/vault-abc/sync.log"
  DIGITAL_GARDEN_SYNC_DIR="$fixture/sync" DIGITAL_GARDEN_METRICS_DIR="$metrics" digital-garden-sync-health
  test ! -e "$metric" || { echo "case 3: expected no metric file" >&2; exit 1; }

  touch "$out"
''
