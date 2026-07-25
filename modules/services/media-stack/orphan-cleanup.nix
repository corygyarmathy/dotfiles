# Orphan Media Cleanup - Remove Unlinked Downloads Without Active Torrents
#
# Identifies and removes files in the downloads/complete directory that:
# 1. Have no hardlinks to the media library (link count = 1)
# 2. Have no corresponding active torrent in qBittorrent
#
# This targets media that was downloaded from a non-private tracker,
# met its upload ratio (torrent removed), and was later superseded by
# a higher-quality import — leaving orphaned files consuming disk space.
#
# SAFETY:
# - Only touches files in downloads/complete (never media library dirs)
# - Skips any file that still has a torrent in qBittorrent
# - Skips files younger than minAgeDays to avoid race conditions
# - Dry-run mode logs what would be deleted without removing anything
# - Removes empty directories after cleanup
#
# SOPS SECRETS REQUIRED:
# - media-stack/qbittorrent/username (shared with qbittorrent module)
# - media-stack/qbittorrent/password (shared with qbittorrent module)
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.orphan-cleanup;
  stack = config.cg.service.media-stack;
  qbt = config.cg.service.qbittorrent;
in
{
  options.cg.service.orphan-cleanup = {
    enable = lib.mkEnableOption "orphan media cleanup for unlinked downloads";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      example = "daily";
      description = ''
        How often to run the cleanup. Uses systemd calendar syntax.
        See systemd.time(7) for valid values.
      '';
    };

    minAgeDays = lib.mkOption {
      type = lib.types.int;
      default = 7;
      description = ''
        Minimum age in days before a file is eligible for cleanup.
        Prevents deleting files that are still being processed by
        Sonarr/Radarr or waiting for import.
      '';
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When true, only log what would be deleted without removing anything.
        Set to false once you've verified the cleanup logic is correct.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Require dependent services
    assertions = [
      {
        assertion = stack.enable;
        message = "orphan-cleanup requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
      {
        assertion = qbt.enable;
        message = "orphan-cleanup requires qbittorrent to be enabled (cg.service.qbittorrent.enable = true)";
      }
    ];

    systemd.services.orphan-cleanup = {
      description = "Remove orphaned downloads with no torrent and no media library links";
      after = [
        "podman-qbittorrent.service"
        "podman-gluetun.service"
      ];

      path = [
        pkgs.curl
        pkgs.jq
        pkgs.findutils
        pkgs.coreutils
      ];

      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [
          "qbt-user:${config.sops.secrets."media-stack/qbittorrent/username".path}"
          "qbt-pass:${config.sops.secrets."media-stack/qbittorrent/password".path}"
        ];
      };

      script =
        let
          completePath = "${stack.dataPath}/downloads/complete";
          qbtPort = toString qbt.port;
          minAge = toString cfg.minAgeDays;
          dryRunFlag = if cfg.dryRun then "true" else "false";
          # On-disk source of truth for how many torrents qBittorrent has.
          btBackupPath = "${stack.configPath}/qbittorrent/qBittorrent/BT_backup";
        in
        ''
          DRY_RUN="${dryRunFlag}"
          COMPLETE_DIR="${completePath}"
          MIN_AGE_DAYS="${minAge}"
          QBT_PORT="${qbtPort}"
          BT_BACKUP_DIR="${btBackupPath}"

          echo "=== Orphan Media Cleanup ==="
          echo "Directory: $COMPLETE_DIR"
          echo "Min age: ''${MIN_AGE_DAYS} days"
          echo "Dry run: $DRY_RUN"
          echo ""

          if [ ! -d "$COMPLETE_DIR" ]; then
            echo "Downloads directory does not exist: $COMPLETE_DIR"
            exit 0
          fi

          # Authenticate with qBittorrent
          QB_USER=$(cat "$CREDENTIALS_DIRECTORY/qbt-user")
          QB_PASS=$(cat "$CREDENTIALS_DIRECTORY/qbt-pass")

          # qBittorrent >=5.2.0 returns 204 on login (not 200) and renamed
          # the session cookie from SID to QBT_SID_<port>. Using a cookie jar
          # file handles both the old and new cookie names transparently.
          COOKIE_JAR=$(mktemp)
          trap 'rm -f "$COOKIE_JAR"' EXIT

          HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
            -c "$COOKIE_JAR" \
            "http://localhost:''${QBT_PORT}/api/v2/auth/login" \
            --data-urlencode "username=$QB_USER" \
            --data-urlencode "password=$QB_PASS")

          if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
            echo "Failed to authenticate with qBittorrent (HTTP $HTTP_CODE)"
            exit 1
          fi

          # ── Wait for qBittorrent to finish loading its torrents ─────────
          # SAFETY GATE (added after the 2026-07-25 incident): the qBittorrent
          # WebUI accepts logins before it has finished loading torrents after a
          # restart, so /torrents/info can briefly return an empty or partial
          # list. Deleting based on that list treats every not-yet-loaded
          # torrent's data as "orphaned" and wipes downloads/complete. Compare the
          # API's torrent count against the .torrent files on disk in BT_backup
          # (the source of truth) and refuse to delete anything until qBittorrent
          # reports at least that many.
          EXPECTED_COUNT=$(find "$BT_BACKUP_DIR" -maxdepth 1 -name '*.torrent' 2>/dev/null | wc -l)
          TORRENTS_JSON=""
          API_COUNT=0
          for attempt in $(seq 1 12); do
            TORRENTS_JSON=$(curl -sf "http://localhost:''${QBT_PORT}/api/v2/torrents/info" -b "$COOKIE_JAR") || TORRENTS_JSON=""
            API_COUNT=$(printf '%s' "$TORRENTS_JSON" | jq 'length' 2>/dev/null || echo 0)
            case "$API_COUNT" in ""|*[!0-9]*) API_COUNT=0 ;; esac
            if [ "$API_COUNT" -gt 0 ] && { [ "$EXPECTED_COUNT" -eq 0 ] || [ "$API_COUNT" -ge "$EXPECTED_COUNT" ]; }; then
              break
            fi
            echo "qBittorrent not ready (loaded $API_COUNT of $EXPECTED_COUNT torrents) — waiting ($attempt/12)..."
            sleep 5
          done

          if [ "$API_COUNT" -eq 0 ]; then
            echo "ERROR: qBittorrent reported 0 torrents after waiting — aborting without deleting anything."
            exit 1
          fi
          if [ "$EXPECTED_COUNT" -gt 0 ] && [ "$API_COUNT" -lt "$EXPECTED_COUNT" ]; then
            echo "ERROR: qBittorrent loaded only $API_COUNT of $EXPECTED_COUNT torrents (still starting up?)."
            echo "Aborting without deleting to avoid orphaning active downloads."
            exit 1
          fi
          echo "qBittorrent ready: $API_COUNT torrents loaded."

          # Build a lookup file of active torrent content paths. Each is the
          # top-level directory or file qBittorrent manages (container path
          # /data/downloads/complete/..., translated to the host path below).
          TORRENT_LIST=$(mktemp)
          trap 'rm -f "$COOKIE_JAR" "$TORRENT_LIST"' EXIT
          printf '%s' "$TORRENTS_JSON" | jq -r '.[] | .content_path // empty' > "$TORRENT_LIST"

          # Note: qBittorrent reports paths using its container mount (/data/downloads/complete/...)
          # We need to compare against the host path, so we translate.
          # Container: /data/downloads/complete -> Host: $COMPLETE_DIR
          CONTAINER_PREFIX="/data/downloads/complete"

          DELETED_COUNT=0
          DELETED_BYTES=0
          SKIPPED_TORRENT=0
          SKIPPED_LINKED=0
          SKIPPED_YOUNG=0

          # Find all files in the complete directory
          while IFS= read -r -d "" FILE; do
            # Check age — skip files newer than MIN_AGE_DAYS
            if [ "$(find "$FILE" -maxdepth 0 -mtime +''${MIN_AGE_DAYS} 2>/dev/null)" = "" ]; then
              SKIPPED_YOUNG=$((SKIPPED_YOUNG + 1))
              continue
            fi

            # Check hardlink count — skip files with links elsewhere (count > 1)
            LINK_COUNT=$(stat -c '%h' "$FILE" 2>/dev/null)
            if [ "$LINK_COUNT" -gt 1 ]; then
              SKIPPED_LINKED=$((SKIPPED_LINKED + 1))
              continue
            fi

            # Check if any active torrent references this file's parent directory
            # Translate host path to container path for comparison
            REL_PATH="''${FILE#$COMPLETE_DIR}"
            CONTAINER_PATH="''${CONTAINER_PREFIX}''${REL_PATH}"

            # Check if this file or any of its parent directories match a torrent content_path
            HAS_TORRENT=false
            CHECK_PATH="$CONTAINER_PATH"
            while [ "$CHECK_PATH" != "$CONTAINER_PREFIX" ] && [ "$CHECK_PATH" != "/" ]; do
              if grep -qxF "$CHECK_PATH" "$TORRENT_LIST" 2>/dev/null; then
                HAS_TORRENT=true
                break
              fi
              CHECK_PATH=$(dirname "$CHECK_PATH")
            done

            if [ "$HAS_TORRENT" = "true" ]; then
              SKIPPED_TORRENT=$((SKIPPED_TORRENT + 1))
              continue
            fi

            # This file is orphaned — no torrent, no hardlinks, old enough
            FILE_SIZE=$(stat -c '%s' "$FILE" 2>/dev/null || echo 0)
            DELETED_BYTES=$((DELETED_BYTES + FILE_SIZE))
            DELETED_COUNT=$((DELETED_COUNT + 1))

            if [ "$DRY_RUN" = "true" ]; then
              echo "[DRY RUN] Would delete: $FILE ($(numfmt --to=iec $FILE_SIZE))"
            else
              echo "Deleting: $FILE ($(numfmt --to=iec $FILE_SIZE))"
              rm -f "$FILE"
            fi
          done < <(find "$COMPLETE_DIR" -type f -print0)

          # Clean up empty directories (bottom-up)
          if [ "$DRY_RUN" = "false" ]; then
            find "$COMPLETE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
            echo "Removed empty directories"
          fi

          echo ""
          echo "=== Summary ==="
          echo "Files to remove: $DELETED_COUNT ($(numfmt --to=iec $DELETED_BYTES))"
          echo "Skipped (active torrent): $SKIPPED_TORRENT"
          echo "Skipped (hardlinked): $SKIPPED_LINKED"
          echo "Skipped (too recent): $SKIPPED_YOUNG"

          if [ "$DRY_RUN" = "true" ] && [ "$DELETED_COUNT" -gt 0 ]; then
            echo ""
            echo "This was a dry run. Set dryRun = false to actually delete files."
          fi
        '';
    };

    systemd.timers.orphan-cleanup = {
      description = "Timer for orphan media cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
