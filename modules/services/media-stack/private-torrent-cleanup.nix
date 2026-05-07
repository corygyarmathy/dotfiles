# Private Torrent Cleanup - Remove Low-Value Private Tracker Seeds When Disk Is Low
#
# When available disk space drops below a configurable threshold, identifies
# private tracker torrents that are no longer useful and removes them in
# priority order until sufficient space is reclaimed:
#
# 1. Uncategorized torrents (freeleech grabs seeded purely for ratio)
# 2. cleanuparr-unlinked torrents (imported but later unlinked from Sonarr/Radarr)
#
# Within each tier, torrents are sorted by total uploaded (ascending) so the
# least-contributing seeds are removed first. Only torrents that have seeded
# for at least minSeedTimeDays are eligible.
#
# Deletion stops as soon as available space exceeds the threshold, preserving
# as much seeding content as possible.
#
# SAFETY:
# - Only targets torrents in the two specific categories above
# - Respects a minimum seed time before any torrent is eligible
# - Stops deleting once the space threshold is met
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
  cfg = config.cg.service.private-torrent-cleanup;
  stack = config.cg.service.media-stack;
  qbt = config.cg.service.qbittorrent;
in
{
  options.cg.service.private-torrent-cleanup = {
    enable = lib.mkEnableOption "private torrent cleanup when disk space is low";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      example = "*-*-* 06:00:00";
      description = ''
        How often to run the cleanup check. Uses systemd calendar syntax.
        See systemd.time(7) for valid values.
      '';
    };

    minFreeGiB = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = ''
        Minimum free disk space in GiB. When available space drops below
        this threshold, cleanup begins. Deletion stops as soon as free
        space exceeds this value.
      '';
    };

    checkPath = lib.mkOption {
      type = lib.types.str;
      default = stack.dataPath;
      description = ''
        Filesystem path used to check available disk space (via df).
        Should point to the ZFS pool or mount where downloads are stored.
      '';
    };

    minSeedTimeDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = ''
        Minimum seeding time in days before a torrent is eligible for
        cleanup. 14 days = 336 hours. Prevents removal of recently
        added content that hasn't had a chance to seed.
      '';
    };

    freeleechCategory = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        qBittorrent category for freeleech downloads. An empty string
        matches uncategorized torrents (the qBittorrent API reports
        uncategorized torrents with category = "").
      '';
    };

    unlinkedCategory = lib.mkOption {
      type = lib.types.str;
      default = "cleanuparr-unlinked";
      description = ''
        qBittorrent category for torrents that Cleanuparr has marked as
        unlinked from Sonarr/Radarr.
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
        message = "private-torrent-cleanup requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
      {
        assertion = qbt.enable;
        message = "private-torrent-cleanup requires qbittorrent to be enabled (cg.service.qbittorrent.enable = true)";
      }
    ];

    systemd.services.private-torrent-cleanup = {
      description = "Remove low-value private tracker seeds when disk space is low";
      after = [
        "podman-qbittorrent.service"
        "podman-gluetun.service"
      ];

      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
        pkgs.findutils
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
          qbtPort = toString qbt.port;
          minFreeGiB = toString cfg.minFreeGiB;
          minSeedSeconds = toString (cfg.minSeedTimeDays * 86400);
          dryRunFlag = if cfg.dryRun then "true" else "false";
          completePath = "${stack.dataPath}/downloads/complete";
          containerPrefix = "/data/downloads/complete";
        in
        ''
          set -euo pipefail

          DRY_RUN="${dryRunFlag}"
          MIN_FREE_GIB="${minFreeGiB}"
          MIN_SEED_SECONDS="${minSeedSeconds}"
          QBT_PORT="${qbtPort}"
          CHECK_PATH="${cfg.checkPath}"
          COMPLETE_DIR="${completePath}"
          CONTAINER_PREFIX="${containerPrefix}"
          FREELEECH_CAT="${cfg.freeleechCategory}"
          UNLINKED_CAT="${cfg.unlinkedCategory}"

          echo "=== Private Torrent Cleanup ==="
          echo "Threshold: ''${MIN_FREE_GIB} GiB free"
          echo "Min seed time: ${toString cfg.minSeedTimeDays} days"
          echo "Freeleech category: '$([ -z "$FREELEECH_CAT" ] && echo "<uncategorized>" || echo "$FREELEECH_CAT")'"
          echo "Unlinked category: $UNLINKED_CAT"
          echo "Dry run: $DRY_RUN"
          echo ""

          # ── Helper: check available space ──────────────────────────────
          get_free_gib() {
            df --output=avail -BG "$CHECK_PATH" | tail -1 | tr -d ' G'
          }

          FREE_GIB=$(get_free_gib)
          echo "Current free space: ''${FREE_GIB} GiB"

          if [ "$FREE_GIB" -ge "$MIN_FREE_GIB" ]; then
            echo "Free space is above threshold, nothing to do."
            exit 0
          fi

          echo "Free space is below threshold, starting cleanup..."
          echo ""

          # ── Authenticate with qBittorrent ──────────────────────────────
          QB_USER=$(cat "$CREDENTIALS_DIRECTORY/qbt-user")
          QB_PASS=$(cat "$CREDENTIALS_DIRECTORY/qbt-pass")

          COOKIE=$(curl -sf -c - "http://localhost:''${QBT_PORT}/api/v2/auth/login" \
            --data-urlencode "username=$QB_USER" \
            --data-urlencode "password=$QB_PASS" 2>/dev/null \
            | grep -oP 'SID\s+\K\S+')

          if [ -z "$COOKIE" ]; then
            echo "ERROR: Failed to authenticate with qBittorrent"
            exit 1
          fi

          # ── Fetch torrent list ─────────────────────────────────────────
          ALL_TORRENTS=$(curl -sf "http://localhost:''${QBT_PORT}/api/v2/torrents/info" \
            --cookie "SID=$COOKIE" 2>/dev/null)

          if [ -z "$ALL_TORRENTS" ]; then
            echo "ERROR: Failed to fetch torrent list from qBittorrent"
            exit 1
          fi

          # ── Filter and sort eligible torrents ──────────────────────────
          # Tier 0 (deleted first): freeleech / uncategorized
          # Tier 1 (deleted second): cleanuparr-unlinked
          # Within each tier: sort by total uploaded ascending (least seeded first)
          #
          # jq outputs: hash \t tier \t uploaded \t size \t name \t content_path
          ELIGIBLE=$(echo "$ALL_TORRENTS" | jq -r --arg fc "$FREELEECH_CAT" --arg uc "$UNLINKED_CAT" --argjson ms "$MIN_SEED_SECONDS" '
            .[]
            | select(
                (.category == $fc or .category == $uc)
                and .seeding_time >= $ms
              )
            | {
                hash,
                tier: (if .category == $fc then 0 else 1 end),
                uploaded,
                size,
                name,
                content_path
              }
            | [.hash, .tier, .uploaded, .size, .name, .content_path]
            | @tsv
          ' | sort -t$'\t' -k2,2n -k3,3n)

          if [ -z "$ELIGIBLE" ]; then
            echo "No eligible torrents found (check categories and seed time)."
            exit 0
          fi

          ELIGIBLE_COUNT=$(echo "$ELIGIBLE" | wc -l)
          echo "Found $ELIGIBLE_COUNT eligible torrent(s)."
          echo ""

          # ── Delete in priority order until space is reclaimed ──────────
          DELETED_COUNT=0
          DELETED_BYTES=0

          while IFS=$'\t' read -r HASH TIER UPLOADED SIZE NAME CONTENT_PATH; do
            # Re-check free space (skip if we've reclaimed enough)
            if [ "$DRY_RUN" = "false" ]; then
              FREE_GIB=$(get_free_gib)
              if [ "$FREE_GIB" -ge "$MIN_FREE_GIB" ]; then
                echo ""
                echo "Free space now ''${FREE_GIB} GiB — threshold met, stopping."
                break
              fi
            fi

            TIER_LABEL=$([ "$TIER" = "0" ] && echo "freeleech" || echo "unlinked")
            SIZE_HUMAN=$(numfmt --to=iec "$SIZE")
            UPLOADED_HUMAN=$(numfmt --to=iec "$UPLOADED")

            if [ "$DRY_RUN" = "true" ]; then
              echo "[DRY RUN] Would delete: $NAME ($SIZE_HUMAN, seeded $UPLOADED_HUMAN, $TIER_LABEL)"
            else
              echo "Deleting: $NAME ($SIZE_HUMAN, seeded $UPLOADED_HUMAN, $TIER_LABEL)"

              # Delete torrent and files via qBittorrent API
              curl -sf "http://localhost:''${QBT_PORT}/api/v2/torrents/delete" \
                --cookie "SID=$COOKIE" \
                --data-urlencode "hashes=$HASH" \
                --data-urlencode "deleteFiles=true"

              # Brief pause to let qBittorrent finish file removal
              sleep 2
            fi

            DELETED_BYTES=$((DELETED_BYTES + SIZE))
            DELETED_COUNT=$((DELETED_COUNT + 1))
          done <<< "$ELIGIBLE"

          # ── Clean up empty directories ─────────────────────────────────
          if [ "$DRY_RUN" = "false" ] && [ "$DELETED_COUNT" -gt 0 ]; then
            find "$COMPLETE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
            echo "Removed empty directories"
          fi

          # ── Summary ────────────────────────────────────────────────────
          echo ""
          echo "=== Summary ==="
          echo "Torrents removed: $DELETED_COUNT of $ELIGIBLE_COUNT eligible"
          echo "Space reclaimed: $(numfmt --to=iec $DELETED_BYTES)"

          if [ "$DRY_RUN" = "false" ]; then
            echo "Free space now: $(get_free_gib) GiB"
          fi

          if [ "$DRY_RUN" = "true" ] && [ "$DELETED_COUNT" -gt 0 ]; then
            echo ""
            echo "This was a dry run. Set dryRun = false to actually delete."
          fi
        '';
    };

    systemd.timers.private-torrent-cleanup = {
      description = "Timer for private torrent cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
